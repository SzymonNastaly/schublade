import { and, eq } from "drizzle-orm"
import { scopeAdmission } from "../archive/document_listing"
import { readStoredRepresentation, representationHeaders } from "../archive/document_representation"
import { isRestrictedScope } from "../authorization/caller_authorization"
import { documents } from "../database/schema"
import { MAIL_MEDIA_TYPE } from "../ingestion/source_file"
import { documentNotFound, problem, undefinedParameters } from "./problem_details"
import type { AuthorizationScope } from "../authorization/caller_authorization"
import type { ArchiveDatabase } from "../database/client"
import type { DocumentRepresentationName } from "./client_paths"

const absenceDetails = {
	original: "The original of this document is not stored",
	text: "The text of this document is not extracted yet",
	thumbnail: "This document has no thumbnail",
} as const satisfies Record<DocumentRepresentationName, string>

function namesEntityTag(conditions: Headers, entityTag: string): boolean {
	const named = conditions.get("If-None-Match")
	return named !== null && named.split(",").some((tag) => [entityTag, "*"].includes(tag.trim().replace(/^W\//, "")))
}

/**
 * Answers GET /api/v1/documents/{id}/original, /text, and /thumbnail. A document the scope does
 * not admit answers the same 404 as one that does not exist. The entity tag of an original is its
 * SHA-256 once the archive recorded it, because the archive never changes the bytes of a content,
 * so a revalidation reads no R2 object. Every other entity tag is R2's, which R2 compares itself.
 */
export async function serveDocumentRepresentationRequest(
	storage: R2Bucket,
	database: ArchiveDatabase,
	request: Request,
	scope: AuthorizationScope,
	documentId: string,
	representation: DocumentRepresentationName,
): Promise<Response> {
	const names = undefinedParameters(request, [])
	if (names !== undefined) return problem(400, `This request takes no parameters, not ${names}`)
	const [document] = await database
		.select({
			id: documents.id,
			storageObjectKey: documents.storageObjectKey,
			mimeType: documents.mimeType,
			originalSha256: documents.originalSha256,
		})
		.from(documents)
		.where(and(eq(documents.id, documentId), scopeAdmission(database, isRestrictedScope(scope) ? scope : undefined)))
	if (!document) return documentNotFound(documentId)
	if (representation === "original" && document.mimeType === MAIL_MEDIA_TYPE) {
		return problem(409, "The archive has not printed this email as a PDF yet. Request the original again later.")
	}

	const headers = representationHeaders("private, no-store")
	const digestTag =
		representation === "original" && document.originalSha256 !== null ? `"${document.originalSha256}"` : undefined
	if (digestTag !== undefined && namesEntityTag(request.headers, digestTag)) {
		headers.set("ETag", digestTag)
		return new Response(null, { status: 304, headers })
	}
	const stored = await readStoredRepresentation(
		storage,
		document,
		representation === "text" ? "content" : representation,
		digestTag === undefined ? request.headers : undefined,
	)
	if (!stored) return problem(404, absenceDetails[representation])
	headers.set("ETag", digestTag ?? stored.metadata.httpEtag)
	if (stored.body === null) return new Response(null, { status: 304, headers })
	stored.metadata.writeHttpMetadata(headers)
	headers.set("Content-Length", String(stored.metadata.size))
	return new Response(stored.body, { headers })
}
