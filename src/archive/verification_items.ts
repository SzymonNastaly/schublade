import { and, asc, desc, eq, isNotNull, isNull } from "drizzle-orm"
import { categories, documentTags, documents, extractedFields, senders, tags } from "../database/schema"
import { illegibleRequiredFields } from "../ingestion/verification_assessment"
import { taxonomyKindModels, taxonomyKinds } from "./taxonomy_maintenance"
import type { ArchiveDatabase } from "../database/client"
import type { DocumentFailureReason, DocumentStatus } from "../ingestion/document_lifecycle"
import type { RequiredFieldKey } from "../ingestion/verification_assessment"
import type { TaxonomyKind } from "./taxonomy_maintenance"

export interface VerificationDocument {
	id: string
	status: DocumentStatus
	mimeType: string
	title: string | null
	documentDate: string | null
	senderName: string | null
}

/**
 * One entry of the Pending verification view, discriminated by its reason. A new record is one
 * entry with every document that refers to it, so one confirmation, rename, or merge resolves
 * them all. A document with a stored reason is an entry of its own.
 */
export type VerificationItem = { createdAt: Date } & (
	| {
			reason: "new_taxonomy_record"
			record: { kind: TaxonomyKind; id: string; name: string }
			documents: Array<VerificationDocument>
	  }
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

async function readUnconfirmedRecords(database: ArchiveDatabase) {
	const recordsByKind = await Promise.all(
		taxonomyKinds.map(async (kind) => {
			const { table } = taxonomyKindModels[kind]
			const records = await database
				.select({ id: table.id, name: table.name, createdAt: table.createdAt })
				.from(table)
				.where(isNull(table.confirmedAt))
			return records.map((record) => ({ kind, ...record }))
		}),
	)
	return recordsByKind.flat()
}

const referringDocumentColumns = {
	id: documents.id,
	status: documents.status,
	mimeType: documents.mimeType,
	title: documents.title,
	documentDate: documents.documentDate,
	senderName: senders.name,
}

const newestDocumentFirst = [desc(documents.createdAt), asc(documents.id)]

/**
 * The documents that refer to each unconfirmed record, newest first. Each query joins the
 * unconfirmed records instead of binding their identifiers, because D1 binds at most 100
 * parameters per query and an archive can hold more records and documents than that.
 */
async function readReferringDocuments(database: ArchiveDatabase) {
	const [sender, category, tag] = await Promise.all([
		database
			.select({ recordId: senders.id, ...referringDocumentColumns })
			.from(documents)
			.innerJoin(senders, and(eq(documents.senderId, senders.id), isNull(senders.confirmedAt)))
			.orderBy(...newestDocumentFirst),
		database
			.select({ recordId: categories.id, ...referringDocumentColumns })
			.from(documents)
			.innerJoin(categories, and(eq(documents.categoryId, categories.id), isNull(categories.confirmedAt)))
			.leftJoin(senders, eq(documents.senderId, senders.id))
			.orderBy(...newestDocumentFirst),
		database
			.select({ recordId: tags.id, ...referringDocumentColumns })
			.from(documentTags)
			.innerJoin(tags, and(eq(documentTags.tagId, tags.id), isNull(tags.confirmedAt)))
			.innerJoin(documents, eq(documentTags.documentId, documents.id))
			.leftJoin(senders, eq(documents.senderId, senders.id))
			.orderBy(...newestDocumentFirst),
	])
	const referringDocuments: Record<TaxonomyKind, Array<VerificationDocument & { recordId: string }>> = {
		sender,
		category,
		tag,
	}
	return referringDocuments
}

/** The entries of the Pending verification view, newest first. */
export async function listVerificationItems(database: ArchiveDatabase): Promise<Array<VerificationItem>> {
	const [records, referringDocuments, flaggedDocuments, failedDocuments, fieldRows] = await Promise.all([
		readUnconfirmedRecords(database),
		readReferringDocuments(database),
		database
			.select({
				...referringDocumentColumns,
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
				...referringDocumentColumns,
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

	const recordItems = records.map(({ kind, id, name, createdAt }): VerificationItem => ({
		reason: "new_taxonomy_record",
		createdAt,
		record: { kind, id, name },
		documents: referringDocuments[kind]
			.filter((document) => document.recordId === id)
			.map(({ recordId: _recordId, ...document }) => document),
	}))
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
	return [...recordItems, ...documentItems, ...failedItems].sort(
		(first, second) => second.createdAt.getTime() - first.createdAt.getTime(),
	)
}

/** The number of entries listVerificationItems returns, for the navigation badge. */
export async function countVerificationItems(database: ArchiveDatabase): Promise<number> {
	const counts = await Promise.all([
		...taxonomyKinds.map((kind) => {
			const { table } = taxonomyKindModels[kind]
			return database.$count(table, isNull(table.confirmedAt))
		}),
		database.$count(documents, flaggedDocument),
		database.$count(documents, failedDocument),
	])
	return counts.reduce((total, count) => total + count, 0)
}
