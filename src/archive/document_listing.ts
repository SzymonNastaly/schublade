import { asc, desc, eq } from "drizzle-orm"
import { categories, documents, extractedFields, householdMembers, senders } from "../database/schema"
import type { ArchiveDatabase } from "../database/client"
import type { DocumentStatus } from "../ingestion/document_lifecycle"
import type { VerificationReason } from "../ingestion/verification_assessment"

interface ListedField {
	fieldKey: string
	value: string | number | null
	confidence: number | null
}

export interface ListedDocument {
	id: string
	status: DocumentStatus
	title: string | null
	documentDate: string | null
	senderName: string | null
	categoryName: string | null
	/** Null when the document concerns the whole household or is not yet classified. */
	personName: string | null
	summary: string | null
	mimeType: string
	pageCount: number | null
	verificationReason: VerificationReason | null
	fields: Array<ListedField>
}

export async function queryDocumentListing(database: ArchiveDatabase): Promise<Array<ListedDocument>> {
	const [rows, fieldRows] = await Promise.all([
		database
			.select({
				id: documents.id,
				status: documents.status,
				title: documents.title,
				documentDate: documents.documentDate,
				senderName: senders.name,
				categoryName: categories.name,
				personName: householdMembers.displayName,
				summary: documents.summary,
				mimeType: documents.mimeType,
				pageCount: documents.pageCount,
				verificationReason: documents.verificationReason,
			})
			.from(documents)
			.leftJoin(senders, eq(documents.senderId, senders.id))
			.leftJoin(categories, eq(documents.categoryId, categories.id))
			.leftJoin(householdMembers, eq(documents.personMemberId, householdMembers.id))
			.orderBy(desc(documents.createdAt), desc(documents.id)),
		database
			.select({
				documentId: extractedFields.documentId,
				fieldKey: extractedFields.fieldKey,
				valueText: extractedFields.valueText,
				valueNumber: extractedFields.valueNumber,
				confidence: extractedFields.confidenceScore,
			})
			.from(extractedFields)
			.orderBy(asc(extractedFields.fieldKey)),
	])
	const fieldsByDocument = new Map<string, Array<ListedField>>()
	for (const field of fieldRows) {
		const listedFields = fieldsByDocument.get(field.documentId) ?? []
		listedFields.push({
			fieldKey: field.fieldKey,
			value: field.valueNumber ?? field.valueText,
			confidence: field.confidence,
		})
		fieldsByDocument.set(field.documentId, listedFields)
	}
	return rows.map((row) => ({ ...row, fields: fieldsByDocument.get(row.id) ?? [] }))
}
