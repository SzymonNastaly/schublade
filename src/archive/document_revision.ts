import { and, eq, inArray, sql } from "drizzle-orm"
import { z } from "zod"
import { categories, documentTags, documents, extractedFields, senders, tags } from "../database/schema"
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
import { assessVerificationReason } from "../ingestion/verification_assessment"
import { indexDocument, removeDocumentFromIndex } from "../search/document_indexing"
import { taxonomyNameSchema } from "./taxonomy_maintenance"
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
 * a confirmed record. `nonArchival: false` keeps a document flagged as a non-archival attachment.
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
	nonArchival: z.boolean().optional(),
})

type DocumentRevision = z.output<typeof documentRevisionSchema>

/** The record a revised name denotes: the existing one, or a confirmed record that the batch inserts. */
const namedRecord = (table: typeof senders | typeof categories, normalizedName: string) =>
	sql<string>`(select ${table.id} from ${table} where ${table.normalizedName} = ${normalizedName})`

async function readRevisedDocument(database: ArchiveDatabase, documentId: string) {
	const [[document], fields] = await Promise.all([
		database
			.select({
				status: documents.status,
				documentDate: documents.documentDate,
				verificationReason: documents.verificationReason,
				categoryExpectedFields: categories.expectedFields,
			})
			.from(documents)
			.leftJoin(categories, eq(documents.categoryId, categories.id))
			.where(eq(documents.id, documentId)),
		database
			.select({ fieldKey: extractedFields.fieldKey, confidence: extractedFields.confidenceScore })
			.from(extractedFields)
			.where(eq(extractedFields.documentId, documentId)),
	])
	if (!document) throw new Error(`Document ${documentId} does not exist`)
	if (document.status !== "archived") throw new Error(`Document ${documentId} is not archived, so it cannot be revised`)
	return { ...document, fields }
}

async function revisedCategoryExpectedFields(
	database: ArchiveDatabase,
	categoryName: string | null | undefined,
	currentExpectedFields: Array<string> | null,
): Promise<ReadonlyArray<string>> {
	if (categoryName === undefined) return currentExpectedFields ?? []
	if (categoryName === null) return []
	const normalizedName = normalizeTaxonomyName(categoryName)
	const [category] = await database
		.select({ expectedFields: categories.expectedFields })
		.from(categories)
		.where(eq(categories.normalizedName, normalizedName))
	return category?.expectedFields ?? findStandardCategory(normalizedName)?.expectedFields ?? []
}

/**
 * Applies a member's revision in one D1 batch, assesses the verification reason again, and
 * uploads the document to AI Search at once. A failed upload leaves the document stale, and the
 * backfill uploads it later.
 */
export async function reviseDocument(
	{ database, storage, searchIndex }: ArchiveEnvironment,
	revision: DocumentRevision,
): Promise<void> {
	const { documentId, senderName, categoryName, tagNames, fields = [] } = revision
	const document = await readRevisedDocument(database, documentId)
	const categoryExpectedFields = await revisedCategoryExpectedFields(
		database,
		categoryName,
		document.categoryExpectedFields,
	)
	const revisedKeys = new Set(fields.map((field) => field.fieldKey))
	const verificationReason = assessVerificationReason({
		nonArchival: revision.nonArchival ?? document.verificationReason === "non_archival_attachment",
		documentDate: revision.documentDate === undefined ? document.documentDate : revision.documentDate,
		categoryExpectedFields,
		fields: [
			...document.fields.filter((field) => !revisedKeys.has(field.fieldKey as ExtractedFieldKey)),
			// A value a member entered carries no confidence.
			...fields.filter((field) => field.value !== null).map((field) => ({ ...field, confidence: null })),
		],
	})
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
						.onConflictDoNothing(),
				]),
		...(categoryName == null || categoryKey == null
			? []
			: [
					database
						.insert(categories)
						.values({
							name: categoryName,
							normalizedName: categoryKey,
							expectedFields: [...categoryExpectedFields],
							confirmedAt,
						})
						.onConflictDoNothing(),
				]),
		...(tagNames ?? []).map((name) =>
			database
				.insert(tags)
				.values({ name, normalizedName: normalizeTaxonomyName(name), confirmedAt })
				.onConflictDoNothing(),
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
				verificationReason,
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
 * Deletes a settled document: its AI Search item, its R2 objects, and then its D1 rows, whose
 * tags and fields cascade. The row goes last, so a deletion that fails part way can run again.
 */
export async function deleteDocument({ database, storage, searchIndex }: ArchiveEnvironment, documentId: string) {
	const [document] = await database
		.select({ status: documents.status })
		.from(documents)
		.where(eq(documents.id, documentId))
	if (!document) return
	if (!isSettledStatus(document.status)) {
		throw new Error(`Document ${documentId} is still being ingested, so it cannot be deleted yet`)
	}
	await removeDocumentFromIndex(searchIndex, documentId)
	const { objects } = await storage.list({ prefix: documentObjectPrefix(documentId) })
	if (objects.length > 0) await storage.delete(objects.map((object) => object.key))
	await database.delete(documents).where(eq(documents.id, documentId))
}
