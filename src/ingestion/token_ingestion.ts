import { authenticateApiToken } from "../authentication/api_tokens"
import { permits } from "../authorization/caller_authorization"
import { connectDatabase } from "../database/client"
import { receiveDocumentUploads } from "./document_upload"

type TokenIngestionEnvironment = Pick<
	Env,
	"ARCHIVE_COORDINATOR" | "DATABASE" | "DOCUMENT_STORAGE" | "DOCUMENT_INGESTION_WORKFLOW"
>

/**
 * Accepts the same multipart files as the browser upload from a caller with an ingest token.
 * A missing token and an unknown one get the same answer, so the answer reveals no token.
 */
export async function receiveTokenIngestion(
	environment: TokenIngestionEnvironment,
	request: Request,
): Promise<Response> {
	if (request.method !== "POST") {
		return Response.json({ error: "Send documents with POST" }, { status: 405, headers: { Allow: "POST" } })
	}
	const caller = await authenticateApiToken(connectDatabase(environment.DATABASE), request.headers.get("Authorization"))
	if (caller === undefined) {
		return Response.json(
			{ error: "Send a valid API token in the Authorization header" },
			{ status: 401, headers: { "WWW-Authenticate": "Bearer" } },
		)
	}
	if (!permits(caller, "ingest")) {
		return Response.json({ error: "The API token does not permit ingesting documents" }, { status: 403 })
	}
	return receiveDocumentUploads(environment, request)
}
