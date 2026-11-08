import { ARCHIVE_CHANGES_PATH, connectToArchiveChanges } from "./archive/archive_changes"
import { requireAccess } from "./authentication/access_verification"
import { crossSiteRequestRejection } from "./authentication/cross_site_requests"
import { receiveTokenIngestion } from "./ingestion/token_ingestion"
import { TOKEN_INGESTION_PATH } from "./ingestion/token_ingestion_path"
import type { Caller } from "./authorization/caller_authorization"

type ApplicationHandler = (request: Request, caller: Caller) => Response | Promise<Response>

type DispatchEnvironment = Pick<
	Env,
	| "ACCESS_TEAM_DOMAIN"
	| "ACCESS_AUD"
	| "ARCHIVE_COORDINATOR"
	| "DATABASE"
	| "DOCUMENT_STORAGE"
	| "DOCUMENT_INGESTION_WORKFLOW"
>

/**
 * Routes every request of the Worker entry. Cross-site writes and WebSocket upgrades are refused
 * first. Exactly the token ingestion path authenticates a bearer token instead of an Access
 * assertion; every other path, including its subpaths and the archive changes socket, stays behind Access.
 */
export function createRequestDispatcher(serveApplication: ApplicationHandler, developmentExemption: boolean) {
	return (request: Request, environment: DispatchEnvironment): Response | Promise<Response> => {
		const rejection = crossSiteRequestRejection(request)
		if (rejection) return rejection
		const { pathname } = new URL(request.url)
		if (pathname === TOKEN_INGESTION_PATH) return receiveTokenIngestion(environment, request)
		const serveMember: ApplicationHandler = (memberRequest, caller) =>
			pathname === ARCHIVE_CHANGES_PATH
				? connectToArchiveChanges(environment, memberRequest)
				: serveApplication(memberRequest, caller)
		return developmentExemption
			? serveMember(request, { kind: "member_session" })
			: requireAccess(serveMember)(request, environment)
	}
}
