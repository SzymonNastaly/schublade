import { desc, eq } from "drizzle-orm"
import { documents, senders } from "../database/schema"
import type { ArchiveDatabase } from "../database/client"
import type { DocumentFailureReason, DocumentStatus } from "../ingestion/document_lifecycle"

export interface VerificationDocument {
	id: string
	status: DocumentStatus
	mimeType: string
	title: string | null
	documentDate: string | null
	senderName: string | null
}

/** One entry of the Pending verification view: a document whose ingestion failed. */
export interface VerificationItem {
	reason: "failed_ingestion"
	createdAt: Date
	document: VerificationDocument
	failureReason: DocumentFailureReason
}

const failedDocument = eq(documents.status, "failed")

const verificationDocumentColumns = {
	id: documents.id,
	status: documents.status,
	mimeType: documents.mimeType,
	title: documents.title,
	documentDate: documents.documentDate,
	senderName: senders.name,
}

/** The entries of the Pending verification view, newest first. */
export async function listVerificationItems(database: ArchiveDatabase): Promise<Array<VerificationItem>> {
	const failedDocuments = await database
		.select({
			...verificationDocumentColumns,
			failureReason: documents.failureReason,
			createdAt: documents.createdAt,
		})
		.from(documents)
		.leftJoin(senders, eq(documents.senderId, senders.id))
		.where(failedDocument)
		.orderBy(desc(documents.createdAt))
	return failedDocuments.map(({ failureReason, createdAt, ...document }): VerificationItem => ({
		reason: "failed_ingestion",
		createdAt,
		document,
		// A document that failed before failure reasons were recorded has none.
		failureReason: failureReason ?? "processing_error",
	}))
}

/** The number of entries listVerificationItems returns, for the navigation badge. */
export async function countVerificationItems(database: ArchiveDatabase): Promise<number> {
	return database.$count(documents, failedDocument)
}
