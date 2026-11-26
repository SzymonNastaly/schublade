import { eq } from "drizzle-orm"
import { connectDatabase } from "../database/client"
import { contents, documents } from "../database/schema"
import { claimContent, lookupContents, sha256Hexadecimal } from "./content_identity"
import { recordIngestionStartFailure, startDocumentIngestion } from "./document_ingestion"
import {
	identifySourceFile,
	originalObjectKey,
	submittedTextObjectKey,
	submittedThumbnailObjectKey,
} from "./source_file"
import type { MailContext } from "./classification_request"
import type { SourceFile } from "./source_file"

export type UploadEnvironment = Pick<
	Env,
	"ARCHIVE_COORDINATOR" | "DATABASE" | "DOCUMENT_STORAGE" | "DOCUMENT_INGESTION_WORKFLOW"
>

// A Worker isolate has 128 MB of memory. Text extraction holds an original three times at once,
// in the R2 read, the Blob for Markdown conversion, and the PDFium heap, so 25 MB per file
// keeps that step near 75 MB.
export const MAXIMUM_DOCUMENT_BYTES = 25_000_000
// The parsed request stays in memory while each file is buffered once more for R2, so 50 MB
// per request keeps the upload near 75 MB as well.
const MAXIMUM_REQUEST_BYTES = 50_000_000
// Each file costs an R2 write, a D1 insert, and a Workflow start in the same invocation, so one
// upload request or one mail message starts at most this many of each.
export const MAXIMUM_FILES_PER_SUBMISSION = 20

export const UNACCEPTED_FILE_KIND = "Only PDF, JPEG, PNG, and WebP files can be archived."

/**
 * An accepted file became a new document. An already archived file's bytes belong to a document
 * the archive holds, which may still be in ingestion. A rejected file cannot be archived as sent.
 * A failed file met a storage error and may succeed again.
 */
export type UploadOutcome =
	| { kind: "accepted"; fileName: string; documentId: string }
	| { kind: "already_archived"; fileName: string; documentId: string }
	| { kind: "rejected"; fileName: string; reason: string }
	| { kind: "failed"; fileName: string; reason: string }

/** What a client derived from the original. A part it did not send is absent. */
export interface DerivedRepresentations {
	text?: Uint8Array<ArrayBuffer>
	thumbnail?: Uint8Array<ArrayBuffer>
	pageCount?: number
}

/**
 * One file with the kind and the digest its sender established. The content is its bytes, or a
 * stream of exactly byteSize bytes that no code of the Worker reads. R2 checks either against the
 * digest as it stores them and throws on a mismatch, before anything else is written.
 */
export interface ContentSubmission {
	content: Uint8Array<ArrayBuffer> | ReadableStream<Uint8Array>
	byteSize: number
	sourceFile: SourceFile
	sha256: string
	derived?: DerivedRepresentations
}

/**
 * Inbound mail derives the document identifier from the message, so a retried delivery finds the
 * document its first delivery recorded. A browser upload gets a random identifier.
 */
interface DocumentOrigin {
	documentId: string
	mailContext?: MailContext
}

type ContentArchival = { kind: "accepted" | "already_archived"; documentId: string }

/**
 * Archives a content once, whichever way its bytes arrive. Bytes a document holds answer with
 * that document before anything is written. Otherwise the original and the representations its
 * client derived go to R2, and one D1 transaction records the document, claims the content for
 * it, and reads which document holds the content. Two uploads of the same bytes can reach that
 * transaction together, and the one that lost removes the objects and the document it recorded
 * and answers with the winner. A content whose document was deleted is archived again.
 */
export async function archiveContent(
	environment: UploadEnvironment,
	{ content, byteSize, sourceFile, sha256, derived = {} }: ContentSubmission,
	{ documentId, mailContext }: DocumentOrigin = { documentId: crypto.randomUUID() },
): Promise<ContentArchival> {
	const database = connectDatabase(environment.DATABASE)
	const [known] = await lookupContents(database, [sha256])
	if (known?.state === "present") return { kind: "already_archived", documentId: known.documentId }
	const storageObjectKey = originalObjectKey(documentId, sourceFile)
	await environment.DOCUMENT_STORAGE.put(storageObjectKey, content, {
		httpMetadata: { contentType: sourceFile.mediaType },
		sha256,
	})
	const derivedObjects = [
		derived.text && {
			key: submittedTextObjectKey(documentId),
			body: derived.text,
			contentType: "text/markdown; charset=utf-8",
		},
		derived.thumbnail && {
			key: submittedThumbnailObjectKey(documentId),
			body: derived.thumbnail,
			contentType: "image/jpeg",
		},
	].filter((object) => object !== undefined)
	const storedObjectKeys = [storageObjectKey, ...derivedObjects.map((object) => object.key)]
	const [recorded, , [claim]] = await Promise.all(
		derivedObjects.map(({ key, body, contentType }) =>
			environment.DOCUMENT_STORAGE.put(key, body, { httpMetadata: { contentType } }),
		),
	)
		.then(() =>
			database.batch([
				database
					.insert(documents)
					.values({
						id: documentId,
						storageObjectKey,
						mimeType: sourceFile.mediaType,
						byteSize,
						pageCount: derived.pageCount,
						originalSha256: sha256,
						status: "processing",
					})
					.onConflictDoNothing()
					.returning({ id: documents.id }),
				claimContent(database, sha256, documentId),
				database.select({ documentId: contents.documentId }).from(contents).where(eq(contents.sha256, sha256)),
			]),
		)
		.catch(async (error: unknown) => {
			// Without its row, nothing would list or remove the stored objects.
			await environment.DOCUMENT_STORAGE.delete(storedObjectKeys)
			throw error
		})
	// The claim in the same transaction leaves the content held, so the fallback never applies.
	const holderId = claim?.documentId ?? documentId
	// A concurrent delivery of the same message recorded the document and started its workflow.
	if (recorded.length === 0) {
		return { kind: holderId === documentId ? "accepted" : "already_archived", documentId: holderId }
	}
	try {
		if (holderId !== documentId) {
			// The objects go before their row, so no failure leaves an object that no row lists.
			await environment.DOCUMENT_STORAGE.delete(storedObjectKeys)
			await database.delete(documents).where(eq(documents.id, documentId))
			return { kind: "already_archived", documentId: holderId }
		}
		await startDocumentIngestion(environment, {
			id: documentId,
			params: mailContext === undefined ? { documentId } : { documentId, mailContext },
		})
		return { kind: "accepted", documentId }
	} catch (error) {
		// A document left processing without a workflow could be neither retried nor deleted, so it fails.
		await recordIngestionStartFailure(environment, documentId)
		throw error
	}
}

/** Checks one file, then archives its content under the origin's document identifier. */
export async function acceptDocumentUpload(
	environment: UploadEnvironment,
	file: File,
	origin?: DocumentOrigin,
): Promise<UploadOutcome> {
	if (file.size > MAXIMUM_DOCUMENT_BYTES) {
		return {
			kind: "rejected",
			fileName: file.name,
			reason: `The file is larger than ${MAXIMUM_DOCUMENT_BYTES / 1_000_000} MB`,
		}
	}
	// R2 rejects a stream of unknown length, so the upload is buffered.
	const content = new Uint8Array(await file.arrayBuffer())
	const sourceFile = identifySourceFile(content)
	if (!sourceFile) return { kind: "rejected", fileName: file.name, reason: UNACCEPTED_FILE_KIND }
	const archival = await archiveContent(
		environment,
		{ content, byteSize: content.byteLength, sourceFile, sha256: await sha256Hexadecimal(content) },
		origin,
	)
	return { ...archival, fileName: file.name }
}

/**
 * The body with its bytes counted as they arrive, because a request need not declare its length
 * in Content-Length. The stream fails once the count passes the limit, and exceeded() says so.
 */
export function limitRequestBody(request: Request, maximumBytes: number) {
	let receivedBytes = 0
	const body = request.body?.pipeThrough(
		new TransformStream<Uint8Array, Uint8Array>({
			transform(chunk, controller) {
				receivedBytes += chunk.byteLength
				if (receivedBytes > maximumBytes) controller.error(new RangeError("The upload exceeds the limit"))
				else controller.enqueue(chunk)
			},
		}),
	)
	return { body, exceeded: () => receivedBytes > maximumBytes }
}

type MultipartBody = { kind: "form"; formData: FormData } | { kind: "too_large" } | { kind: "malformed" }

async function readLimitedFormData(request: Request): Promise<MultipartBody> {
	const { body, exceeded } = limitRequestBody(request, MAXIMUM_REQUEST_BYTES)
	const contentType = request.headers.get("Content-Type") ?? ""
	try {
		return {
			kind: "form",
			formData: await new Response(body, { headers: { "Content-Type": contentType } }).formData(),
		}
	} catch (error) {
		if (exceeded()) return { kind: "too_large" }
		// workerd raises a TypeError for a body that is not multipart or URL-encoded form data.
		if (error instanceof TypeError) return { kind: "malformed" }
		throw error
	}
}

/**
 * Accepts the files of a multipart request whose fields are named files, one outcome per file. The
 * route is the ingest route of a token or the browser's upload, and multipart carries no text.
 */
export async function receiveDocumentUploads(
	environment: UploadEnvironment,
	request: Request,
	route: "ingest" | "documents",
): Promise<Response> {
	const body = await readLimitedFormData(request)
	if (body.kind === "too_large") {
		return Response.json(
			{ error: `The upload is larger than ${MAXIMUM_REQUEST_BYTES / 1_000_000} MB. Upload fewer files at once.` },
			{ status: 413 },
		)
	}
	const files = body.kind === "form" ? body.formData.getAll("files").filter((entry) => entry instanceof File) : []
	if (files.length === 0) {
		return Response.json({ error: "Send the documents as multipart form fields named files" }, { status: 400 })
	}
	const outcomes: Array<UploadOutcome> = []
	for (const [index, file] of files.entries()) {
		if (index >= MAXIMUM_FILES_PER_SUBMISSION) {
			outcomes.push({
				kind: "rejected",
				fileName: file.name,
				reason: `An upload accepts at most ${MAXIMUM_FILES_PER_SUBMISSION} files. Upload this file again.`,
			})
			continue
		}
		console.log(`Document reception: route=${route} text=absent thumbnail=absent`)
		try {
			outcomes.push(await acceptDocumentUpload(environment, file))
		} catch (error) {
			console.error(`Storing the upload ${file.name} failed`, error)
			outcomes.push({
				kind: "failed",
				fileName: file.name,
				reason: "The archive could not store the file. Upload it again.",
			})
		}
	}
	return Response.json({ outcomes })
}
