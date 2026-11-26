import { ARCHIVE_CHANGES_PATH, connectToArchiveChanges } from "./archive/archive_changes"
import { requireAccess } from "./authentication/access_verification"
import { crossSiteRequestRejection } from "./authentication/cross_site_requests"
import { matchClientRoute } from "./client_protocol/client_paths"
import { serveClientRequest } from "./client_protocol/client_requests"
import { problem } from "./client_protocol/problem_details"
import { MEMBER_RECEPTION_PATTERN, receiveDocument } from "./ingestion/document_reception"
import { receiveTokenIngestion } from "./ingestion/token_ingestion"
import { TOKEN_INGESTION_PATH } from "./ingestion/token_ingestion_path"
import { serveAuthorizationServer } from "./model_context_protocol/authorization_server"
import { ACCESS_BYPASSING_PATHS, CONSENT_PATH } from "./model_context_protocol/authorization_server_paths"
import { serveGrantConsent } from "./model_context_protocol/grant_consent"
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
	| "OAUTH_KV"
	| "SEARCH_INDEX"
>

const accessBypassingPaths = new Set(ACCESS_BYPASSING_PATHS)

/**
 * Routes every request of the Worker entry. Cross-site writes and WebSocket upgrades are refused
 * first. Exactly the token ingestion path, the client routes, and the paths of OAuth clients
 * authenticate a bearer token, or need no credential, instead of an Access assertion. Every other
 * path, including their subpaths, the archive changes socket, the consent page, and the path at
 * which a member's browser sends a document, stays behind Access.
 */
export function createRequestDispatcher(serveApplication: ApplicationHandler, developmentExemption: boolean) {
	return (
		request: Request,
		environment: DispatchEnvironment,
		context: ExecutionContext,
	): Response | Promise<Response> => {
		const rejection = crossSiteRequestRejection(request)
		if (rejection) return rejection
		const { pathname } = new URL(request.url)
		if (pathname === TOKEN_INGESTION_PATH) return receiveTokenIngestion(environment, request)
		const clientRoute = matchClientRoute(pathname)
		if (clientRoute) return serveClientRequest(environment, request, clientRoute)
		if (accessBypassingPaths.has(pathname)) return serveAuthorizationServer(request, environment, context)
		const serveMember: ApplicationHandler = (memberRequest, caller) => {
			if (pathname === ARCHIVE_CHANGES_PATH) return connectToArchiveChanges(environment, memberRequest)
			if (pathname === CONSENT_PATH) return serveGrantConsent(environment, memberRequest, caller)
			// Matched here so that the body reaches the reception as the stream workerd made.
			const memberReception = MEMBER_RECEPTION_PATTERN.exec(pathname)
			if (memberReception) {
				if (memberRequest.method !== "PUT") {
					return problem(405, "Send this request with PUT", { Allow: "PUT" })
				}
				return receiveDocument(environment, memberRequest, {
					route: "submitted_documents",
					sha256: memberReception[1] ?? "",
				})
			}
			return serveApplication(memberRequest, caller)
		}
		return developmentExemption
			? serveMember(request, { kind: "member_session" })
			: requireAccess(serveMember)(request, environment)
	}
}
