import { requireAccess } from "./authentication/access_verification"
import { crossSiteWriteRejection } from "./authentication/cross_site_writes"
import { TOKEN_INGESTION_PATH, receiveTokenIngestion } from "./ingestion/token_ingestion"
import type { Caller } from "./authorization/caller_authorization"

type ApplicationHandler = (request: Request, caller: Caller) => Response | Promise<Response>

type DispatchEnvironment = Pick<
	Env,
	"ACCESS_TEAM_DOMAIN" | "ACCESS_AUD" | "DATABASE" | "DOCUMENT_STORAGE" | "DOCUMENT_INGESTION_WORKFLOW"
>

/**
 * Routes every request of the Worker entry. Cross-site writes are refused first. Exactly the token
 * ingestion path authenticates a bearer token instead of an Access assertion; every other path,
 * including its subpaths, stays behind Access.
 */
export function createRequestDispatcher(serveApplication: ApplicationHandler, developmentExemption: boolean) {
	const serveWithinAccess = requireAccess(serveApplication)
	return (request: Request, environment: DispatchEnvironment): Response | Promise<Response> => {
		const rejection = crossSiteWriteRejection(request)
		if (rejection) return rejection
		if (new URL(request.url).pathname === TOKEN_INGESTION_PATH) return receiveTokenIngestion(environment, request)
		return developmentExemption
			? serveApplication(request, { kind: "member_session" })
			: serveWithinAccess(request, environment)
	}
}
