import { desc, eq } from "drizzle-orm"
import { documents } from "../database/schema"
import type { ArchiveDatabase } from "../database/client"
import type { DocumentFailureReason } from "../ingestion/document_lifecycle"

export interface FailedDocument {
	id: string
	title: string | null
	failureReason: DocumentFailureReason
}

const failedStatus = eq(documents.status, "failed")

/** The documents whose ingestion failed, newest first. */
export async function listFailedDocuments(database: ArchiveDatabase): Promise<Array<FailedDocument>> {
	const failedDocuments = await database
		.select({ id: documents.id, title: documents.title, failureReason: documents.failureReason })
		.from(documents)
		.where(failedStatus)
		.orderBy(desc(documents.createdAt))
	return failedDocuments.map(({ failureReason, ...document }) => ({
		...document,
		// A document that failed before failure reasons were recorded has none.
		failureReason: failureReason ?? "processing_error",
	}))
}

export async function countFailedDocuments(database: ArchiveDatabase): Promise<number> {
	return database.$count(documents, failedStatus)
}
