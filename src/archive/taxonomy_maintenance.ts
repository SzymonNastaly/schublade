import { and, eq, exists, inArray, isNull, ne, notExists, sql } from "drizzle-orm"
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
import { normalizeTaxonomyName } from "../ingestion/taxonomy_resolution"
import { assessVerificationReason } from "../ingestion/verification_assessment"
import type { SQL } from "drizzle-orm"
import type { ArchiveDatabase } from "../database/client"

export const taxonomyKinds = ["sender", "category", "tag"] as const

export type TaxonomyKind = (typeof taxonomyKinds)[number]

/** A sender, category, or tag name must hold a letter or digit, or it identifies nothing. */
export const taxonomyNameSchema = z
	.string()
	.trim()
	.min(1)
	.refine((name) => normalizeTaxonomyName(name) !== "", "A name needs a letter or a digit")

/**
 * What sets the three kinds of record apart: the table, the documents that refer to a record,
 * and whether the AI Search item of such a document carries the record's name. The index
 * content names the sender and the tags, while the metadata holds only identifiers.
 */
export const taxonomyKindModels = {
	sender: {
		table: senders,
		referringDocuments: (recordId: string): SQL => eq(documents.senderId, recordId),
		nameIndexed: true,
	},
	category: {
		table: categories,
		referringDocuments: (recordId: string): SQL => eq(documents.categoryId, recordId),
		nameIndexed: false,
	},
	tag: {
		table: tags,
		referringDocuments: (recordId: string): SQL =>
			inArray(
				documents.id,
				sql`(select ${documentTags.documentId} from ${documentTags} where ${documentTags.tagId} = ${recordId})`,
			),
		nameIndexed: true,
	},
} as const

export const taxonomyRecordSchema = z.strictObject({ kind: z.enum(taxonomyKinds), recordId: z.uuid() })

type TaxonomyRecordReference = z.infer<typeof taxonomyRecordSchema>

export const taxonomyRenameSchema = taxonomyRecordSchema.extend({ name: taxonomyNameSchema })

export const taxonomyMergeSchema = z
	.strictObject({ kind: z.enum(taxonomyKinds), sourceRecordId: z.uuid(), targetRecordId: z.uuid() })
	.refine((merge) => merge.sourceRecordId !== merge.targetRecordId, "A record cannot merge into itself")

type TaxonomyMerge = z.infer<typeof taxonomyMergeSchema>

/** Keeps the time of an earlier confirmation. */
const confirmation = (table: (typeof taxonomyKindModels)[TaxonomyKind]["table"]) =>
	sql`coalesce(${table.confirmedAt}, unixepoch())`

/** A rename that would give the record another record's name proposes merging into that record instead. */
export type TaxonomyRenameOutcome =
	{ kind: "renamed" } | { kind: "merge_proposed"; targetRecord: { id: string; name: string } }

/** A member's confirmation. Confirming a confirmed record changes nothing. */
export async function confirmTaxonomyRecord(
	database: ArchiveDatabase,
	{ kind, recordId }: TaxonomyRecordReference,
): Promise<void> {
	const { table } = taxonomyKindModels[kind]
	const confirmed = await database
		.update(table)
		.set({ confirmedAt: confirmation(table) })
		.where(eq(table.id, recordId))
		.returning({ id: table.id })
	if (confirmed.length === 0) throw new Error(`The ${kind} ${recordId} does not exist`)
}

/**
 * Renames and confirms the record. Documents whose AI Search item carries the name become
 * stale, and the backfill uploads them again.
 */
export async function renameTaxonomyRecord(
	database: ArchiveDatabase,
	{ kind, recordId, name }: z.infer<typeof taxonomyRenameSchema>,
): Promise<TaxonomyRenameOutcome> {
	const { table, referringDocuments, nameIndexed } = taxonomyKindModels[kind]
	const normalizedName = normalizeTaxonomyName(name)
	const [namesake] = await database
		.select({ id: table.id, name: table.name })
		.from(table)
		.where(and(eq(table.normalizedName, normalizedName), ne(table.id, recordId)))
	if (namesake) return { kind: "merge_proposed", targetRecord: namesake }
	const [renamed] = await database.batch([
		database
			.update(table)
			.set({ name, normalizedName, confirmedAt: confirmation(table) })
			.where(eq(table.id, recordId))
			.returning({ id: table.id }),
		...(nameIndexed
			? [
					database
						.update(documents)
						.set({ updatedAt: succeedingModificationTime() })
						.where(referringDocuments(recordId)),
				]
			: []),
	])
	if (renamed.length === 0) throw new Error(`The ${kind} ${recordId} does not exist`)
	return { kind: "renamed" }
}

/**
 * Deletes a record that no member confirmed and no document refers to, such as the sender of a
 * deleted attachment. Deleting a record that no longer exists changes nothing.
 */
export async function deleteTaxonomyRecord(
	database: ArchiveDatabase,
	{ kind, recordId }: TaxonomyRecordReference,
): Promise<void> {
	const { table, referringDocuments } = taxonomyKindModels[kind]
	const deleted = await database
		.delete(table)
		.where(
			and(
				eq(table.id, recordId),
				isNull(table.confirmedAt),
				notExists(database.select({ id: documents.id }).from(documents).where(referringDocuments(recordId))),
			),
		)
		.returning({ id: table.id })
	if (deleted.length > 0) return
	const [record] = await database.select({ confirmedAt: table.confirmedAt }).from(table).where(eq(table.id, recordId))
	if (record === undefined) return
	throw new Error(
		record.confirmedAt === null
			? `Documents still refer to the ${kind} ${recordId}`
			: `The ${kind} ${recordId} is confirmed, so only a merge removes it`,
	)
}

/** The archived documents of the source category whose verification reason differs under the target's expected fields. */
async function reassessMovedDocuments(database: ArchiveDatabase, sourceRecordId: string, targetRecordId: string) {
	const movedDocument = and(eq(documents.categoryId, sourceRecordId), eq(documents.status, "archived"))
	const [[target], movedDocuments, fields] = await Promise.all([
		database
			.select({ expectedFields: categories.expectedFields })
			.from(categories)
			.where(eq(categories.id, targetRecordId)),
		database
			.select({
				id: documents.id,
				documentDate: documents.documentDate,
				verificationReason: documents.verificationReason,
			})
			.from(documents)
			.where(movedDocument),
		database
			.select({
				documentId: extractedFields.documentId,
				fieldKey: extractedFields.fieldKey,
				confidence: extractedFields.confidenceScore,
			})
			.from(extractedFields)
			.innerJoin(documents, eq(extractedFields.documentId, documents.id))
			.where(movedDocument),
	])
	return movedDocuments.flatMap((document) => {
		const verificationReason = assessVerificationReason({
			nonArchival: document.verificationReason === "non_archival_attachment",
			documentDate: document.documentDate,
			categoryExpectedFields: target?.expectedFields ?? [],
			fields: fields.filter((field) => field.documentId === document.id),
		})
		return verificationReason === document.verificationReason ? [] : [{ documentId: document.id, verificationReason }]
	})
}

/**
 * Moves every document and tag link from the source record to the target, confirms the target,
 * and deletes the source, in one D1 batch. Each moved document becomes stale, and the backfill
 * uploads it again with the target's identifier and name. A merge whose source no longer exists,
 * such as a repeated one, changes nothing and throws, so it never confirms a target on its own.
 * A category merge assesses the verification reason of each moved document again against the
 * target's expected fields, so a receipt without an amount that moves into a category that
 * requires one awaits verification.
 */
export async function mergeTaxonomyRecords(
	database: ArchiveDatabase,
	{ kind, sourceRecordId, targetRecordId }: TaxonomyMerge,
): Promise<void> {
	const { table, referringDocuments } = taxonomyKindModels[kind]
	const [target] = await database.select({ id: table.id }).from(table).where(eq(table.id, targetRecordId))
	if (!target) throw new Error(`The ${kind} ${targetRecordId} to merge into does not exist`)
	const reassignment =
		kind === "tag"
			? database
					.insert(documentTags)
					.select(
						database
							.select({ documentId: documentTags.documentId, tagId: sql<string>`${targetRecordId}`.as("tag_id") })
							.from(documentTags)
							.where(eq(documentTags.tagId, sourceRecordId)),
					)
					.onConflictDoNothing()
			: database
					.update(documents)
					.set(kind === "sender" ? { senderId: targetRecordId } : { categoryId: targetRecordId })
					.where(referringDocuments(sourceRecordId))
	const reassessments =
		kind === "category" ? await reassessMovedDocuments(database, sourceRecordId, targetRecordId) : []
	const [, , confirmed] = await database.batch([
		database
			.update(documents)
			.set({ updatedAt: succeedingModificationTime() })
			.where(referringDocuments(sourceRecordId)),
		reassignment,
		database
			.update(table)
			.set({ confirmedAt: confirmation(table) })
			.where(
				and(
					eq(table.id, targetRecordId),
					exists(database.select({ id: table.id }).from(table).where(eq(table.id, sourceRecordId))),
				),
			)
			.returning({ id: table.id }),
		// Deleting the source tag also deletes its links, which cascade.
		database.delete(table).where(eq(table.id, sourceRecordId)),
		...reassessments.map(({ documentId, verificationReason }) =>
			database
				.update(documents)
				.set({ verificationReason })
				.where(and(eq(documents.id, documentId), eq(documents.categoryId, targetRecordId))),
		),
	])
	if (confirmed.length === 0) throw new Error(`The ${kind} ${sourceRecordId} to merge does not exist`)
}
