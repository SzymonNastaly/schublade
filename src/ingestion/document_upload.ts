import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { recordDocumentStatus } from "./document_ingestion"
import { acceptedMediaTypes, identifySourceFile, originalObjectKey } from "./source_file"

type UploadEnvironment = Pick<Env, "DATABASE" | "DOCUMENT_STORAGE" | "DOCUMENT_INGESTION_WORKFLOW">

export type UploadOutcome =
	{ kind: "accepted"; fileName: string; documentId: string } | { kind: "rejected"; fileName: string; reason: string }

/** Stores the original in R2, records the document as processing, and starts its ingestion workflow. */
async function acceptDocumentUpload(environment: UploadEnvironment, file: File): Promise<UploadOutcome> {
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
	await database.insert(documents).values({
		id: documentId,
		storageObjectKey,
		mimeType: sourceFile.mediaType,
		byteSize: file.size,
		status: "processing",
	})
	try {
		await environment.DOCUMENT_INGESTION_WORKFLOW.create({ id: documentId, params: { documentId } })
	} catch (error) {
		await recordDocumentStatus(database, documentId, "failed")
		throw error
	}
	return { kind: "accepted", fileName: file.name, documentId }
}

/** Accepts the files of a multipart request whose fields are named files, one outcome per file. */
export async function receiveDocumentUploads(environment: UploadEnvironment, request: Request): Promise<Response> {
	const formData = await request.formData()
	const files = formData.getAll("files").filter((entry) => entry instanceof File)
	if (files.length === 0) {
		return Response.json({ error: "Send the documents as multipart form fields named files" }, { status: 400 })
	}
	const outcomes: Array<UploadOutcome> = []
	for (const file of files) outcomes.push(await acceptDocumentUpload(environment, file))
	return Response.json({ outcomes })
}
