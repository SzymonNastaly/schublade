import { and, eq } from "drizzle-orm"
import { digestBackfillRefusal, documentStatusResponse } from "../client_protocol/collection_requests"
import { problem } from "../client_protocol/problem_details"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { lookupContents } from "./content_identity"
import { retryDocumentIngestion } from "./document_ingestion"
import { isUsableSubmittedText } from "./document_text"
import { MAXIMUM_DOCUMENT_BYTES, archiveContent } from "./document_upload"
import { parseReceptionHeaders } from "./reception_headers"
import {
	UNACCEPTED_FILE_KIND,
	identifySourceFile,
	submittedTextObjectKey,
	submittedThumbnailObjectKey,
} from "./source_file"
import type { ArchiveDatabase } from "../database/client"
import type { DerivedRepresentations, UploadEnvironment } from "./document_upload"
import type { ReceptionLayout } from "./reception_headers"
import type { SourceFile } from "./source_file"

/**
 * The paths that receive one document named by its digest. A collector must never bring back a
 * document the owner deleted and must wait while a digest is missing, because it sends whatever
 * it finds. A person chose to send, so a deleted content is archived again. The route of the
 * collector builds before derived representations takes the original alone.
 */
const receptionRules = {
	submitted_documents: { collectorRules: false, acceptsDerivedRepresentations: true },
	collected_documents: { collectorRules: true, acceptsDerivedRepresentations: true },
	contents: { collectorRules: true, acceptsDerivedRepresentations: false },
} as const satisfies Record<string, { collectorRules: boolean; acceptsDerivedRepresentations: boolean }>

export type ReceptionRoute = keyof typeof receptionRules

/** The path at which a member's browser sends a document, behind Access. */
export const MEMBER_RECEPTION_PATTERN = /^\/api\/submitted_documents\/([0-9a-f]{64})$/

// identifySourceFile reads at most the first 12 bytes of a file.
const SIGNATURE_BYTES = 12

type BodyRefusal = { kind: "refused"; status: 400 | 415; detail: string }

type ReceptionBody =
	| { kind: "received"; original: ReadableStream<Uint8Array>; sourceFile: SourceFile; derived: DerivedRepresentations }
	| BodyRefusal

type DerivedPrefix = { kind: "read"; text: Uint8Array<ArrayBuffer>; thumbnail: Uint8Array<ArrayBuffer> } | BodyRefusal

const TRUNCATED_BODY: BodyRefusal = {
	kind: "refused",
	status: 400,
	detail: "The body is shorter than its Content-Length",
}

async function readCounted(reader: ReadableStreamBYOBReader, byteCount: number) {
	if (byteCount === 0) return new Uint8Array(0)
	const { value } = await reader.readAtLeast(byteCount, new Uint8Array(byteCount))
	return value?.byteLength === byteCount ? value : undefined
}

/** Reads the counted text and thumbnail that open the body. */
async function readDerivedPrefix(reader: ReadableStreamBYOBReader, layout: ReceptionLayout): Promise<DerivedPrefix> {
	const text = await readCounted(reader, layout.textByteCount)
	const thumbnail = await readCounted(reader, layout.thumbnailByteCount)
	if (text === undefined || thumbnail === undefined) return TRUNCATED_BODY
	if (thumbnail.byteLength > 0 && !(thumbnail[0] === 0xff && thumbnail[1] === 0xd8 && thumbnail[2] === 0xff)) {
		return { kind: "refused", status: 415, detail: "The thumbnail must be a JPEG" }
	}
	return { kind: "read", text, thumbnail }
}

/**
 * Reads the counted text and thumbnail and the leading bytes of the original, then hands on the
 * original as a stream of its exact length, which R2 requires. The leading bytes go back into
 * that stream, and the rest of the body is piped through without any code reading it.
 */
async function readReceptionBody(body: ReadableStream | null, layout: ReceptionLayout): Promise<ReceptionBody> {
	if (body === null) return TRUNCATED_BODY
	const reader = body.getReader({ mode: "byob" })
	const prefix = await readDerivedPrefix(reader, layout)
	if (prefix.kind === "refused") return prefix
	const { text, thumbnail } = prefix
	const leading = await readCounted(reader, Math.min(SIGNATURE_BYTES, layout.originalByteCount))
	reader.releaseLock()
	if (leading === undefined) return TRUNCATED_BODY
	const sourceFile = identifySourceFile(leading)
	if (!sourceFile) return { kind: "refused", status: 415, detail: UNACCEPTED_FILE_KIND }
	const original = new FixedLengthStream(layout.originalByteCount)
	const writer = original.writable.getWriter()
	// A body that ends early or fails errors the stream, and the R2 write that reads it fails.
	writer
		.write(leading)
		.then(() => {
			writer.releaseLock()
			return body.pipeTo(original.writable)
		})
		.catch(() => undefined)
	return {
		kind: "received",
		original: original.readable,
		sourceFile,
		derived: {
			...(text.byteLength > 0 && { text }),
			...(thumbnail.byteLength > 0 && { thumbnail }),
			...(layout.pageCount !== undefined && { pageCount: layout.pageCount }),
		},
	}
}

/**
 * A failed document holds its content, so the same bytes again would change nothing. A text the
 * client read lets ingestion succeed without the reading that failed, so the text and thumbnail
 * replace the document's and it is retried. The original is never read, because the archive holds
 * it. Returns undefined when the holder has not failed or the text is too short to change anything.
 */
async function retryWithSubmittedText(
	environment: UploadEnvironment,
	database: ArchiveDatabase,
	body: ReadableStream | null,
	layout: ReceptionLayout,
	documentId: string,
): Promise<Response | undefined> {
	const [holder] = await database
		.select({ status: documents.status })
		.from(documents)
		.where(eq(documents.id, documentId))
	if (holder?.status !== "failed" || body === null) return undefined
	const reader = body.getReader({ mode: "byob" })
	const prefix = await readDerivedPrefix(reader, layout)
	reader.releaseLock()
	if (prefix.kind === "refused") return problem(prefix.status, prefix.detail)
	if (!isUsableSubmittedText(new TextDecoder().decode(prefix.text))) return undefined
	const markdown = { httpMetadata: { contentType: "text/markdown; charset=utf-8" } }
	await Promise.all([
		environment.DOCUMENT_STORAGE.put(submittedTextObjectKey(documentId), prefix.text, markdown),
		prefix.thumbnail.byteLength > 0 &&
			environment.DOCUMENT_STORAGE.put(submittedThumbnailObjectKey(documentId), prefix.thumbnail, {
				httpMetadata: { contentType: "image/jpeg" },
			}),
		layout.pageCount !== undefined &&
			database
				.update(documents)
				.set({ pageCount: layout.pageCount })
				.where(and(eq(documents.id, documentId), eq(documents.status, "failed"))),
	])
	await retryDocumentIngestion(environment, documentId)
	return documentStatusResponse(database, documentId, 202)
}

// R2 names a digest mismatch with this code, and the message carries no other stable part.
function isDigestMismatch(error: unknown): boolean {
	return error instanceof Error && error.message.includes("(10037)")
}

/**
 * Receives one document whose body is its text, its thumbnail, and its original, in that order,
 * as reception_headers.ts counts them. Every refusal but a wrong kind or a wrong digest comes
 * from the headers and D1 alone, and a content a document holds answers before the body is read.
 */
export async function receiveDocument(
	environment: UploadEnvironment,
	request: Request,
	{ route, sha256 }: { route: ReceptionRoute; sha256: string },
): Promise<Response> {
	const database = connectDatabase(environment.DATABASE)
	const { collectorRules, acceptsDerivedRepresentations } = receptionRules[route]
	if (collectorRules) {
		const refusal = await digestBackfillRefusal(database)
		if (refusal) return refusal
	}
	const [known] = await lookupContents(database, [sha256])
	if (collectorRules && known?.state === "deleted") {
		return problem(409, "The owner deleted this document. Only an upload through the browser brings it back.")
	}
	const headers = parseReceptionHeaders(
		request.headers,
		new URL(request.url).searchParams,
		MAXIMUM_DOCUMENT_BYTES,
		acceptsDerivedRepresentations,
	)
	if (headers.kind === "refused") return problem(headers.status, headers.detail)
	const { layout } = headers
	// Shows whether documents still arrive without a text, from builds before clients read them.
	console.log(
		`Document reception: route=${route} text=${layout.textByteCount > 0 ? "submitted" : "absent"} thumbnail=${layout.thumbnailByteCount > 0 ? "submitted" : "absent"}`,
	)
	if (known?.state === "present") {
		const retried =
			layout.textByteCount > 0 &&
			(await retryWithSubmittedText(environment, database, request.body, layout, known.documentId))
		return retried || documentStatusResponse(database, known.documentId)
	}
	const body = await readReceptionBody(request.body, layout)
	if (body.kind === "refused") return problem(body.status, body.detail)
	try {
		const archival = await archiveContent(environment, {
			content: body.original,
			byteSize: layout.originalByteCount,
			sourceFile: body.sourceFile,
			sha256,
			derived: body.derived,
		})
		return await documentStatusResponse(database, archival.documentId, archival.kind === "accepted" ? 202 : 200)
	} catch (error) {
		if (isDigestMismatch(error)) {
			console.warn(`R2 refused the original of ${sha256}`, error)
			return problem(422, "The original does not have the SHA-256 in the path")
		}
		throw error
	}
}
