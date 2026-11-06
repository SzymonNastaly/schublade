import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { recordDocumentStatus } from "./document_ingestion"
import { acceptedMediaTypes, identifySourceFile, originalObjectKey } from "./source_file"

type UploadEnvironment = Pick<Env, "DATABASE" | "DOCUMENT_STORAGE" | "DOCUMENT_INGESTION_WORKFLOW">

// A Worker isolate has 128 MB of memory. Text extraction holds an original three times at once,
// in the R2 read, the Blob for Markdown conversion, and the PDFium heap, so 25 MB per file
// keeps that step near 75 MB.
const MAXIMUM_DOCUMENT_BYTES = 25_000_000
// The parsed request stays in memory while each file is buffered once more for R2, so 50 MB
// per request keeps the upload near 75 MB as well.
const MAXIMUM_REQUEST_BYTES = 50_000_000

/** A rejected file cannot be archived as sent. A failed file met a storage error and may succeed again. */
export type UploadOutcome =
	| { kind: "accepted"; fileName: string; documentId: string }
	| { kind: "rejected"; fileName: string; reason: string }
	| { kind: "failed"; fileName: string; reason: string }

/** Checks one file, stores the original in R2, records the document as processing, and starts its workflow. */
async function acceptDocumentUpload(environment: UploadEnvironment, file: File): Promise<UploadOutcome> {
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
	if (!sourceFile) {
		return {
			kind: "rejected",
			fileName: file.name,
			reason: `The content of the file is not one of ${acceptedMediaTypes.join(", ")}`,
		}
	}
	const database = connectDatabase(environment.DATABASE)
	const documentId = crypto.randomUUID()
	const storageObjectKey = originalObjectKey(documentId, sourceFile)
	await environment.DOCUMENT_STORAGE.put(storageObjectKey, content, {
		httpMetadata: { contentType: sourceFile.mediaType },
	})
	try {
		await database.insert(documents).values({
			id: documentId,
			storageObjectKey,
			mimeType: sourceFile.mediaType,
			byteSize: file.size,
			status: "processing",
		})
	} catch (error) {
		// Without its row, nothing would list or remove the stored original.
		await environment.DOCUMENT_STORAGE.delete(storageObjectKey)
		throw error
	}
	try {
		await environment.DOCUMENT_INGESTION_WORKFLOW.create({ id: documentId, params: { documentId } })
	} catch (error) {
		await recordDocumentStatus(database, documentId, "failed")
		throw error
	}
	return { kind: "accepted", fileName: file.name, documentId }
}

/**
 * Parses the multipart body, or returns undefined once it exceeds MAXIMUM_REQUEST_BYTES. The bytes
 * are counted as they arrive, because a request need not declare its length in Content-Length.
 */
async function readLimitedFormData(request: Request): Promise<FormData | undefined> {
	let receivedBytes = 0
	const limitedBody = request.body?.pipeThrough(
		new TransformStream<Uint8Array, Uint8Array>({
			transform(chunk, controller) {
				receivedBytes += chunk.byteLength
				if (receivedBytes > MAXIMUM_REQUEST_BYTES) controller.error(new RangeError("The upload exceeds the limit"))
				else controller.enqueue(chunk)
			},
		}),
	)
	const contentType = request.headers.get("Content-Type") ?? ""
	try {
		return await new Response(limitedBody, { headers: { "Content-Type": contentType } }).formData()
	} catch (error) {
		if (receivedBytes > MAXIMUM_REQUEST_BYTES) return undefined
		throw error
	}
}

/** Accepts the files of a multipart request whose fields are named files, one outcome per file. */
export async function receiveDocumentUploads(environment: UploadEnvironment, request: Request): Promise<Response> {
	const formData = await readLimitedFormData(request)
	if (formData === undefined) {
		return Response.json(
			{ error: `The upload is larger than ${MAXIMUM_REQUEST_BYTES / 1_000_000} MB. Upload fewer files at once.` },
			{ status: 413 },
		)
	}
	const files = formData.getAll("files").filter((entry) => entry instanceof File)
	if (files.length === 0) {
		return Response.json({ error: "Send the documents as multipart form fields named files" }, { status: 400 })
	}
	const outcomes: Array<UploadOutcome> = []
	for (const file of files) {
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
