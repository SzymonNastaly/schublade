import { z } from "zod"
import { queryDocumentStatuses } from "../archive/document_listing"
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
import { documentStatusPath } from "./client_paths"
import { documentNotFound, problem } from "./problem_details"
import type { ArchiveDatabase } from "../database/client"
import type { UploadEnvironment } from "../ingestion/document_upload"

const MAXIMUM_LOOKUP_DIGESTS = 1000
// The Cron Trigger runs the digest backfill every 15 minutes.
const DIGEST_BACKFILL_INTERVAL_SECONDS = 900
// 1000 digests take 67 KB as compact JSON, so this leaves room for indentation and line breaks.
const MAXIMUM_LOOKUP_BYTES = 128_000

const contentLookupSchema = z.strictObject({
	sha256: z.array(z.string().regex(sha256Pattern)).min(1).max(MAXIMUM_LOOKUP_DIGESTS),
})

/**
 * Until every document has its digest, a lookup would call archived bytes absent, and an upload of
 * them would make a second document, so both wait for the scheduled backfill.
 */
async function digestBackfillRefusal(database: ArchiveDatabase): Promise<Response | undefined> {
	if (!(await awaitsContentDigests(database))) return undefined
	return problem(503, "The archive is still recording the digests of its documents. Send the request again later.", {
		"Retry-After": String(DIGEST_BACKFILL_INTERVAL_SECONDS),
	})
}

export async function documentStatusResponse(
	database: ArchiveDatabase,
	documentId: string,
	status: 200 | 202 = 200,
): Promise<Response> {
	const [record] = await queryDocumentStatuses(database, [documentId])
	if (!record) return documentNotFound(documentId)
	return Response.json(
		{ document_id: record.documentId, status: record.status, failure_reason: record.failureReason },
		{ status, headers: { Location: documentStatusPath(record.documentId) } },
	)
}

export async function serveContentLookup(database: ArchiveDatabase, request: Request): Promise<Response> {
	const refusal = await digestBackfillRefusal(database)
	if (refusal) return refusal
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

// A content the owner deleted is refused by the digest in the path, before the body is read, so no
// collector can bring the document back and none pays an upload for the refusal. A person's upload
// through the browser, a token, or mail still goes through archiveContent, which archives it again.
// A digest other than the one in the path means the bytes were corrupted on the way or sent in error,
// so they are refused before their kind is read, which corrupted bytes could fail for good.
export async function serveContentSubmission(
	environment: UploadEnvironment,
	database: ArchiveDatabase,
	request: Request,
	sha256: string,
): Promise<Response> {
	const refusal = await digestBackfillRefusal(database)
	if (refusal) return refusal
	const [known] = await lookupContents(database, [sha256])
	if (known?.state === "deleted") {
		return problem(409, "The owner deleted this document. Only an upload through the browser brings it back.")
	}
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
