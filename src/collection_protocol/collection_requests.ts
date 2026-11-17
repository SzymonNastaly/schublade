import { z } from "zod"
import { queryDocumentStatuses } from "../archive/document_listing"
import { authenticateApiToken } from "../authentication/api_tokens"
import { permits } from "../authorization/caller_authorization"
import { connectDatabase } from "../database/client"
import { sha256Pattern } from "../database/schema"
import { awaitsContentDigests, lookupContents, sha256Hexadecimal } from "../ingestion/content_identity"
import {
	MAXIMUM_DOCUMENT_BYTES,
	UNACCEPTED_FILE_KIND,
	archiveContent,
	limitRequestBody,
	readDocumentBody,
} from "../ingestion/document_upload"
import { identifySourceFile } from "../ingestion/source_file"
import { documentStatusPath } from "./collection_paths"
import type { ArchiveDatabase } from "../database/client"
import type { UploadEnvironment } from "../ingestion/document_upload"
import type { CollectionRoute } from "./collection_paths"

const MAXIMUM_LOOKUP_DIGESTS = 1000
// The Cron Trigger runs the digest backfill every 15 minutes.
const DIGEST_BACKFILL_INTERVAL_SECONDS = 900
// 1000 digests take 67 KB as compact JSON, so this leaves room for indentation and line breaks.
const MAXIMUM_LOOKUP_BYTES = 128_000

const contentLookupSchema = z.strictObject({
	sha256: z.array(z.string().regex(sha256Pattern)).min(1).max(MAXIMUM_LOOKUP_DIGESTS),
})

/**
 * The reason phrase of each status an answer can carry. Every problem has the type about:blank,
 * which RFC 9457 reserves for a problem that the status code describes in full, so a collector
 * reads the status and the detail sentence.
 */
const problemTitles = {
	400: "Bad Request",
	401: "Unauthorized",
	403: "Forbidden",
	404: "Not Found",
	405: "Method Not Allowed",
	413: "Content Too Large",
	415: "Unsupported Media Type",
	422: "Unprocessable Content",
	500: "Internal Server Error",
	503: "Service Unavailable",
} as const satisfies Record<number, string>

type ProblemStatus = keyof typeof problemTitles

function problem(status: ProblemStatus, detail: string, headers: Record<string, string> = {}): Response {
	return Response.json(
		{ type: "about:blank", title: problemTitles[status], status, detail },
		{ status, headers: { ...headers, "Content-Type": "application/problem+json" } },
	)
}

async function documentStatusResponse(
	database: ArchiveDatabase,
	documentId: string,
	status: 200 | 202 = 200,
): Promise<Response> {
	const [record] = await queryDocumentStatuses(database, [documentId])
	if (!record) return problem(404, `No document has the identifier ${documentId}`)
	return Response.json(
		{ document_id: record.documentId, status: record.status, failure_reason: record.failureReason },
		{ status, headers: { Location: documentStatusPath(record.documentId) } },
	)
}

async function serveContentLookup(database: ArchiveDatabase, request: Request): Promise<Response> {
	const limited = limitRequestBody(request, MAXIMUM_LOOKUP_BYTES)
	const body: unknown = await new Response(limited.body).json().catch(() => undefined)
	if (limited.exceeded()) {
		return problem(
			413,
			`The lookup is larger than ${MAXIMUM_LOOKUP_BYTES / 1000} KB. Send at most ${MAXIMUM_LOOKUP_DIGESTS} digests.`,
		)
	}
	const lookup = contentLookupSchema.safeParse(body)
	if (!lookup.success) {
		return problem(
			400,
			body === undefined
				? "Send a JSON object whose sha256 member lists the digests to look up"
				: z.prettifyError(lookup.error),
		)
	}
	const states = await lookupContents(database, lookup.data.sha256)
	return Response.json({
		contents: states.map((state) =>
			state.state === "present"
				? { sha256: state.sha256, state: state.state, document_id: state.documentId }
				: { sha256: state.sha256, state: state.state },
		),
	})
}

// A digest other than the one in the path means the bytes were corrupted on the way or sent in error,
// so they are refused before their kind is read, which corrupted bytes could fail for good.
async function serveContentSubmission(
	environment: UploadEnvironment,
	database: ArchiveDatabase,
	request: Request,
	sha256: string,
): Promise<Response> {
	const body = await readDocumentBody(request)
	if (body.kind === "too_large") {
		return problem(413, `The file is larger than ${MAXIMUM_DOCUMENT_BYTES / 1_000_000} MB`)
	}
	const received = await sha256Hexadecimal(body.content)
	if (received !== sha256) return problem(422, `The body has the SHA-256 ${received}, not the one in the path`)
	const sourceFile = identifySourceFile(body.content)
	if (!sourceFile) return problem(415, UNACCEPTED_FILE_KIND)
	const archival = await archiveContent(environment, { content: body.content, sourceFile, sha256 })
	return documentStatusResponse(database, archival.documentId, archival.kind === "accepted" ? 202 : 200)
}

/**
 * Answers a collector request on a matched route: the method, then the ingest token, then the
 * route. A missing token and an unknown one get the same answer, so the answer reveals no token.
 * Every answer but a document is a problem details document.
 */
export async function serveCollectionRequest(
	environment: UploadEnvironment,
	request: Request,
	route: CollectionRoute,
): Promise<Response> {
	if (request.method !== route.method) {
		return problem(405, `Send this request with ${route.method}`, { Allow: route.method })
	}
	const database = connectDatabase(environment.DATABASE)
	const caller = await authenticateApiToken(database, request.headers.get("Authorization"))
	if (caller === undefined) {
		return problem(401, "Send a valid API token in the Authorization header", { "WWW-Authenticate": "Bearer" })
	}
	if (!permits(caller, "ingest")) return problem(403, "The API token does not permit ingesting documents")
	try {
		// Until every document has its digest, a lookup would call archived bytes absent, and an
		// upload of them would make a second document, so both wait for the scheduled backfill.
		if (route.kind !== "document_status" && (await awaitsContentDigests(database))) {
			return problem(
				503,
				"The archive is still recording the digests of its documents. Send the request again later.",
				{
					"Retry-After": String(DIGEST_BACKFILL_INTERVAL_SECONDS),
				},
			)
		}
		switch (route.kind) {
			case "content_lookup":
				return await serveContentLookup(database, request)
			case "content_submission":
				return await serveContentSubmission(environment, database, request, route.sha256)
			case "document_status":
				return await documentStatusResponse(database, route.documentId)
		}
	} catch (error) {
		console.error(`The collector request ${request.method} ${new URL(request.url).pathname} failed`, error)
		return problem(500, "The archive could not complete the request. Send it again.")
	}
}
