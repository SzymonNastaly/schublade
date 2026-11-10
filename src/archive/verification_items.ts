import { and, eq } from "drizzle-orm"
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

/** One entry of the Pending verification view, discriminated by its reason. */
export type VerificationItem = { createdAt: Date } & (
	| { reason: "non_archival_attachment"; document: VerificationDocument }
	| { reason: "failed_ingestion"; document: VerificationDocument; failureReason: DocumentFailureReason }
)

// A document archived earlier may still store illegible_required_field, which awaits nobody now.
const flaggedDocument = and(
	eq(documents.verificationReason, "non_archival_attachment"),
	eq(documents.status, "archived"),
)
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
	const [flaggedDocuments, failedDocuments] = await Promise.all([
		database
			.select({ ...verificationDocumentColumns, createdAt: documents.createdAt })
			.from(documents)
			.leftJoin(senders, eq(documents.senderId, senders.id))
			.where(flaggedDocument),
		database
			.select({
				...verificationDocumentColumns,
				failureReason: documents.failureReason,
				createdAt: documents.createdAt,
			})
			.from(documents)
			.leftJoin(senders, eq(documents.senderId, senders.id))
			.where(failedDocument),
	])

	const documentItems = flaggedDocuments.map(({ createdAt, ...document }): VerificationItem => ({
		reason: "non_archival_attachment",
		createdAt,
		document,
	}))
	const failedItems = failedDocuments.map(({ failureReason, createdAt, ...document }): VerificationItem => ({
		reason: "failed_ingestion",
		createdAt,
		document,
		// A document that failed before failure reasons were recorded has none.
		failureReason: failureReason ?? "processing_error",
	}))
	return [...documentItems, ...failedItems].sort(
		(first, second) => second.createdAt.getTime() - first.createdAt.getTime(),
	)
}

/** The number of entries listVerificationItems returns, for the navigation badge. */
export async function countVerificationItems(database: ArchiveDatabase): Promise<number> {
	const counts = await Promise.all([
		database.$count(documents, flaggedDocument),
		database.$count(documents, failedDocument),
	])
	return counts.reduce((total, count) => total + count, 0)
}
