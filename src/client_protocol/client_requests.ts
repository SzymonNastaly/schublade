import { authenticateApiToken } from "../authentication/api_tokens"
import { permits } from "../authorization/caller_authorization"
import { connectDatabase } from "../database/client"
import { levelRefusals } from "./client_paths"
import { documentStatusResponse, serveContentLookup, serveContentSubmission } from "./collection_requests"
import { serveAuthorization, serveChanges } from "./journal_requests"
import { problem } from "./problem_details"
import { serveDocumentRepresentationRequest } from "./representation_requests"
import type { UploadEnvironment } from "../ingestion/document_upload"
import type { MatchedRoute } from "./client_paths"

/**
 * Answers a request on a matched route: the method, then the token, then the route's level, then
 * the route. No handler reads the Authorization header or checks a level. A missing token and an
 * unknown one get the same answer, so the answer reveals no token. Every answer but a route's
 * success is a problem details document.
 */
export async function serveClientRequest(
	environment: UploadEnvironment,
	request: Request,
	{ method, level, route }: MatchedRoute,
): Promise<Response> {
	if (request.method !== method) return problem(405, `Send this request with ${method}`, { Allow: method })
	const database = connectDatabase(environment.DATABASE)
	const caller = await authenticateApiToken(database, request.headers.get("Authorization"))
	if (caller === undefined) {
		return problem(401, "Send a valid API token in the Authorization header", { "WWW-Authenticate": "Bearer" })
	}
	if (!permits(caller, level)) return problem(403, levelRefusals[level])
	try {
		switch (route.kind) {
			case "authorization":
				return await serveAuthorization(database, request, caller)
			case "changes":
				return await serveChanges(database, request, caller)
			case "document_representation":
				return await serveDocumentRepresentationRequest(
					environment.DOCUMENT_STORAGE,
					database,
					request,
					caller.scope,
					route.documentId,
					route.representation,
				)
			case "content_lookup":
				return await serveContentLookup(database, request)
			case "content_submission":
				return await serveContentSubmission(environment, database, request, route.sha256)
			case "document_status":
				return await documentStatusResponse(database, route.documentId)
		}
	} catch (error) {
		console.error(`The client request ${request.method} ${new URL(request.url).pathname} failed`, error)
		return problem(500, "The archive could not complete the request. Send it again.")
	}
}
