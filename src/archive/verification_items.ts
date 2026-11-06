import { and, asc, desc, eq, inArray, isNotNull, isNull } from "drizzle-orm"
import { categories, documentTags, documents, extractedFields, senders } from "../database/schema"
import { illegibleRequiredFields } from "../ingestion/verification_assessment"
import { taxonomyKindModels, taxonomyKinds } from "./taxonomy_maintenance"
import type { ArchiveDatabase } from "../database/client"
import type { RequiredFieldKey } from "../ingestion/verification_assessment"
import type { TaxonomyKind } from "./taxonomy_maintenance"

export interface VerificationDocument {
	id: string
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
)

const flaggedDocument = and(isNotNull(documents.verificationReason), eq(documents.status, "archived"))

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

/** Which documents refer to each record, as pairs of record and document identifiers. */
async function readReferences(database: ArchiveDatabase, recordIds: Array<string>) {
	if (recordIds.length === 0) return []
	const [senderReferences, categoryReferences, tagReferences] = await Promise.all([
		database
			.select({ recordId: senders.id, documentId: documents.id })
			.from(documents)
			.innerJoin(senders, eq(documents.senderId, senders.id))
			.where(inArray(senders.id, recordIds)),
		database
			.select({ recordId: categories.id, documentId: documents.id })
			.from(documents)
			.innerJoin(categories, eq(documents.categoryId, categories.id))
			.where(inArray(categories.id, recordIds)),
		database
			.select({ recordId: documentTags.tagId, documentId: documentTags.documentId })
			.from(documentTags)
			.where(inArray(documentTags.tagId, recordIds)),
	])
	return [...senderReferences, ...categoryReferences, ...tagReferences]
}

/** The entries of the Pending verification view, newest first. */
export async function listVerificationItems(database: ArchiveDatabase): Promise<Array<VerificationItem>> {
	const records = await readUnconfirmedRecords(database)
	const references = await readReferences(
		database,
		records.map((record) => record.id),
	)
	const documentColumns = {
		id: documents.id,
		title: documents.title,
		documentDate: documents.documentDate,
		senderName: senders.name,
	}
	const [flaggedDocuments, referringDocuments] = await Promise.all([
		database
			.select({
				...documentColumns,
				reason: documents.verificationReason,
				createdAt: documents.createdAt,
				categoryExpectedFields: categories.expectedFields,
			})
			.from(documents)
			.leftJoin(senders, eq(documents.senderId, senders.id))
			.leftJoin(categories, eq(documents.categoryId, categories.id))
			.where(flaggedDocument),
		references.length === 0
			? []
			: database
					.select(documentColumns)
					.from(documents)
					.leftJoin(senders, eq(documents.senderId, senders.id))
					.where(
						inArray(
							documents.id,
							references.map((reference) => reference.documentId),
						),
					)
					.orderBy(desc(documents.createdAt), asc(documents.id)),
	])
	const illegibleDocumentIds = flaggedDocuments
		.filter((document) => document.reason === "illegible_required_field")
		.map((document) => document.id)
	const fieldRows =
		illegibleDocumentIds.length === 0
			? []
			: await database
					.select({
						documentId: extractedFields.documentId,
						fieldKey: extractedFields.fieldKey,
						valueText: extractedFields.valueText,
						valueNumber: extractedFields.valueNumber,
						confidence: extractedFields.confidenceScore,
					})
					.from(extractedFields)
					.where(inArray(extractedFields.documentId, illegibleDocumentIds))

	const recordItems: Array<VerificationItem> = records.map(({ kind, id, name, createdAt }) => {
		const documentIds = new Set(
			references.filter((reference) => reference.recordId === id).map((reference) => reference.documentId),
		)
		return {
			reason: "new_taxonomy_record",
			createdAt,
			record: { kind, id, name },
			documents: referringDocuments.filter((document) => documentIds.has(document.id)),
		}
	})
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
	return [...recordItems, ...documentItems].sort(
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
	])
	return counts.reduce((total, count) => total + count, 0)
}
