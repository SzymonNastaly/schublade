import { and, eq, inArray, sql } from "drizzle-orm"
import { z } from "zod"
import {
	categories,
	documentTags,
	documents,
	extractedFields,
	senders,
	succeedingModificationTime,
	tags,
} from "../database/schema"
import {
	MAXIMUM_TAG_COUNT,
	extractedFieldKeys,
	extractedFieldTypes,
	findStandardCategory,
	normalizeFieldValue,
} from "../ingestion/document_classification"
import { isSettledStatus } from "../ingestion/document_lifecycle"
import { documentObjectPrefix } from "../ingestion/source_file"
import { normalizeTaxonomyName } from "../ingestion/taxonomy_resolution"
import { indexDocument, removeDocumentFromIndex } from "../search/document_indexing"
import { confirmation, taxonomyNameSchema } from "./taxonomy_maintenance"
import type { BatchItem } from "drizzle-orm/batch"
import type { ArchiveDatabase } from "../database/client"
import type { ExtractedFieldKey } from "../ingestion/document_classification"
import type { SearchIndex } from "../search/document_indexing"

interface ArchiveEnvironment {
	database: ArchiveDatabase
	storage: R2Bucket
	searchIndex: SearchIndex
}

/** A null value removes the field. Each value is normalized as the classifier's values are. */
const revisedFieldsSchema = z
	.partialRecord(z.enum(extractedFieldKeys), z.union([z.string(), z.number()]).nullable())
	.transform((fields, context) =>
		(Object.entries(fields) as Array<[ExtractedFieldKey, string | number | null | undefined]>).flatMap(
			([fieldKey, value]) => {
				if (value === undefined) return []
				const normalized = value === null ? null : normalizeFieldValue(fieldKey, value)
				if (value !== null && normalized === null) {
					context.addIssue({ code: "custom", path: [fieldKey], message: `${value} is no valid ${fieldKey}` })
					return []
				}
				return [{ fieldKey, value: normalized }]
			},
		),
	)

/**
 * A member's revision of an archived document. Each attribute that is present replaces the
 * stored one, and a null clears it. A sender, category, or tag name that no record has creates
 * a confirmed record, and the name of an unconfirmed record confirms that record.
 */
export const documentRevisionSchema = z.strictObject({
	documentId: z.uuid(),
	title: z.string().trim().min(1).nullable().optional(),
	documentDate: z.iso.date().nullable().optional(),
	senderName: taxonomyNameSchema.nullable().optional(),
	categoryName: taxonomyNameSchema.nullable().optional(),
	/** Null assigns the document to the whole household. */
	personMemberId: z.uuid().nullable().optional(),
	tagNames: z.array(taxonomyNameSchema).max(MAXIMUM_TAG_COUNT).optional(),
	fields: revisedFieldsSchema.optional(),
})

type DocumentRevision = z.output<typeof documentRevisionSchema>

/** The record a revised name denotes: the existing one, or a confirmed record that the batch inserts. */
const namedRecord = (table: typeof senders | typeof categories, normalizedName: string) =>
	sql<string>`(select ${table.id} from ${table} where ${table.normalizedName} = ${normalizedName})`

async function requireArchivedDocument(database: ArchiveDatabase, documentId: string): Promise<void> {
	const [document] = await database
		.select({ status: documents.status })
		.from(documents)
		.where(eq(documents.id, documentId))
	if (!document) throw new Error(`Document ${documentId} does not exist`)
	if (document.status !== "archived") throw new Error(`Document ${documentId} is not archived, so it cannot be revised`)
}

/**
 * Applies a member's revision in one D1 batch and uploads the document to AI Search at once.
 * A failed upload leaves the document stale, and the backfill uploads it later.
 */
export async function reviseDocument(
	{ database, storage, searchIndex }: ArchiveEnvironment,
	revision: DocumentRevision,
): Promise<void> {
	const { documentId, senderName, categoryName, tagNames, fields = [] } = revision
	await requireArchivedDocument(database, documentId)
	const confirmedAt = new Date()
	const senderKey = senderName == null ? senderName : normalizeTaxonomyName(senderName)
	const categoryKey = categoryName == null ? categoryName : normalizeTaxonomyName(categoryName)

	const statements: Array<BatchItem<"sqlite">> = [
		...(senderName == null || senderKey == null
			? []
			: [
					database
						.insert(senders)
						.values({ name: senderName, normalizedName: senderKey, confirmedAt })
						.onConflictDoUpdate({ target: senders.normalizedName, set: { confirmedAt: confirmation(senders) } }),
				]),
		...(categoryName == null || categoryKey == null
			? []
			: [
					database
						.insert(categories)
						.values({
							name: categoryName,
							normalizedName: categoryKey,
							expectedFields: [...(findStandardCategory(categoryKey)?.expectedFields ?? [])],
							confirmedAt,
						})
						.onConflictDoUpdate({ target: categories.normalizedName, set: { confirmedAt: confirmation(categories) } }),
				]),
		...(tagNames ?? []).map((name) =>
			database
				.insert(tags)
				.values({ name, normalizedName: normalizeTaxonomyName(name), confirmedAt })
				.onConflictDoUpdate({ target: tags.normalizedName, set: { confirmedAt: confirmation(tags) } }),
		),
		database
			.update(documents)
			.set({
				...(revision.title !== undefined && { title: revision.title }),
				...(revision.documentDate !== undefined && { documentDate: revision.documentDate }),
				...(senderKey !== undefined && { senderId: senderKey === null ? null : namedRecord(senders, senderKey) }),
				...(categoryKey !== undefined && {
					categoryId: categoryKey === null ? null : namedRecord(categories, categoryKey),
				}),
				...(revision.personMemberId !== undefined && { personMemberId: revision.personMemberId }),
				// A revision of only tags or fields changes no column of the row, yet makes the document stale.
				updatedAt: succeedingModificationTime(),
			})
			.where(eq(documents.id, documentId)),
		...(tagNames === undefined
			? []
			: [
					database.delete(documentTags).where(eq(documentTags.documentId, documentId)),
					...(tagNames.length === 0
						? []
						: [
								database
									.insert(documentTags)
									.select(
										database
											.select({ documentId: sql<string>`${documentId}`.as("document_id"), tagId: tags.id })
											.from(tags)
											.where(inArray(tags.normalizedName, tagNames.map(normalizeTaxonomyName))),
									)
									.onConflictDoNothing(),
							]),
				]),
		...fields.map(({ fieldKey, value }) => {
			if (value === null) {
				return database
					.delete(extractedFields)
					.where(and(eq(extractedFields.documentId, documentId), eq(extractedFields.fieldKey, fieldKey)))
			}
			const stored = {
				fieldType: extractedFieldTypes[fieldKey],
				valueText: typeof value === "number" ? null : value,
				valueNumber: typeof value === "number" ? value : null,
				confidenceScore: null,
			}
			return database
				.insert(extractedFields)
				.values({ documentId, fieldKey, ...stored })
				.onConflictDoUpdate({ target: [extractedFields.documentId, extractedFields.fieldKey], set: stored })
		}),
	]
	const [firstStatement, ...laterStatements] = statements
	if (firstStatement) await database.batch([firstStatement, ...laterStatements])

	try {
		await indexDocument(database, storage, searchIndex, documentId)
	} catch (error) {
		console.error(
			`Document ${documentId} awaits the backfill: ${error instanceof Error ? error.message : String(error)}`,
		)
	}
}

/**
 * Deletes a settled document: its AI Search item, its R2 objects, its D1 rows, whose tags and
 * fields cascade, and then its AI Search item again. A backfill that read the row before it went
 * can upload the document after the first removal, and the second removal deletes that item. A
 * deletion that fails part way, even after the row went, converges when it runs again.
 */
export async function deleteDocument({ database, storage, searchIndex }: ArchiveEnvironment, documentId: string) {
	const [document] = await database
		.select({ status: documents.status })
		.from(documents)
		.where(eq(documents.id, documentId))
	if (document && !isSettledStatus(document.status)) {
		throw new Error(`Document ${documentId} is still being ingested, so it cannot be deleted yet`)
	}
	await removeDocumentFromIndex(searchIndex, documentId)
	const { objects } = await storage.list({ prefix: documentObjectPrefix(documentId) })
	if (objects.length > 0) await storage.delete(objects.map((object) => object.key))
	await database.delete(documents).where(eq(documents.id, documentId))
	await removeDocumentFromIndex(searchIndex, documentId)
}
