import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { recordDocumentStatus } from "./document_ingestion"
import { acceptedMediaTypes, originalObjectKey, parseSourceFile } from "./source_file"

type UploadEnvironment = Pick<Env, "DATABASE" | "DOCUMENT_STORAGE" | "DOCUMENT_INGESTION_WORKFLOW">

export type UploadOutcome =
	{ kind: "accepted"; fileName: string; documentId: string } | { kind: "rejected"; fileName: string; reason: string }

/** Stores the original in R2, records the document as processing, and starts its ingestion workflow. */
export async function acceptDocumentUpload(environment: UploadEnvironment, file: File): Promise<UploadOutcome> {
	const sourceFile = parseSourceFile(file.type)
	if (!sourceFile) {
		return {
			kind: "rejected",
			fileName: file.name,
			reason: `The file type ${file.type || "(none)"} is not one of ${acceptedMediaTypes.join(", ")}`,
		}
	}
	const database = connectDatabase(environment.DATABASE)
	const documentId = crypto.randomUUID()
	const storageObjectKey = originalObjectKey(documentId, sourceFile)
	// R2 rejects a stream of unknown length, so the upload is buffered.
	await environment.DOCUMENT_STORAGE.put(storageObjectKey, await file.arrayBuffer(), {
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
