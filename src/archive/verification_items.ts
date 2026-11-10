import { and, eq, isNotNull } from "drizzle-orm"
import { categories, documents, extractedFields, senders } from "../database/schema"
import { illegibleRequiredFields } from "../ingestion/verification_assessment"
import type { ArchiveDatabase } from "../database/client"
import type { DocumentFailureReason, DocumentStatus } from "../ingestion/document_lifecycle"
import type { RequiredFieldKey } from "../ingestion/verification_assessment"

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
	| {
			reason: "illegible_required_field"
			document: VerificationDocument
			illegibleFields: Array<{ fieldKey: RequiredFieldKey; value: string | number | null }>
	  }
	| { reason: "non_archival_attachment"; document: VerificationDocument }
	| { reason: "failed_ingestion"; document: VerificationDocument; failureReason: DocumentFailureReason }
)

const flaggedDocument = and(isNotNull(documents.verificationReason), eq(documents.status, "archived"))
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
	const [flaggedDocuments, failedDocuments, fieldRows] = await Promise.all([
		database
			.select({
				...verificationDocumentColumns,
				reason: documents.verificationReason,
				createdAt: documents.createdAt,
				categoryExpectedFields: categories.expectedFields,
			})
			.from(documents)
			.leftJoin(senders, eq(documents.senderId, senders.id))
			.leftJoin(categories, eq(documents.categoryId, categories.id))
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
		database
			.select({
				documentId: extractedFields.documentId,
				fieldKey: extractedFields.fieldKey,
				valueText: extractedFields.valueText,
				valueNumber: extractedFields.valueNumber,
				confidence: extractedFields.confidenceScore,
			})
			.from(extractedFields)
			.innerJoin(documents, eq(extractedFields.documentId, documents.id))
			.where(and(flaggedDocument, eq(documents.verificationReason, "illegible_required_field"))),
	])

	const documentItems = flaggedDocuments.map(
		({ reason, createdAt, categoryExpectedFields, ...document }): VerificationItem => {
			if (reason !== "illegible_required_field") return { reason: "non_archival_attachment", createdAt, document }
			const fields = fieldRows.filter((field) => field.documentId === document.id)
			const illegibleFields = illegibleRequiredFields({
				documentDate: document.documentDate,
				categoryExpectedFields: categoryExpectedFields ?? [],
				fields,
			}).map((fieldKey) => {
				const field = fields.find((candidate) => candidate.fieldKey === fieldKey)
				return { fieldKey, value: field?.valueNumber ?? field?.valueText ?? null }
			})
			return { reason, createdAt, document, illegibleFields }
		},
	)
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
