import { applyD1Migrations, env, reset } from "cloudflare:test"
import { asc, eq } from "drizzle-orm"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { categories, documentTags, documents, extractedFields, senders, tags } from "../database/schema"
import { contentObjectKey } from "../ingestion/source_file"
import { indexDocument, indexMissingDocuments } from "../search/document_indexing"
import { createInMemorySearchIndex } from "../search/in_memory_search_index"
import { deleteTaxonomyRecord, mergeTaxonomyRecords, renameTaxonomyRecord } from "./taxonomy_maintenance"
import { listVerificationItems } from "./verification_items"

const insurerAlias = { id: "0a6f2c41-9d3e-4b58-8a71-5e2d9c0b4f13", name: "Allianz Versicherungs-AG" }
const insurer = { id: "7c3e9b10-4a2d-4f86-9e15-b8d0a6c2e947", name: "Allianz SE" }
const taxAlias = { id: "2b7d4e90-1c5a-4e3f-8b62-0f9a7d3c5e18", name: "steuer" }
const taxYear = { id: "9e1c5a73-6b2f-4d08-a4e9-3c7b1f0d2a56", name: "tax-2026" }
const policyId = "4d2a8f61-3e7c-4b95-9a10-6c5e2b8d7f34"
const statementId = "8b5e1d27-9f4a-4c63-b2e8-1a7d3c6f9e05"
const contractId = "c3f7a2e8-5b1d-4e96-8c40-2d9b6a1e7f53"

async function archive(documentId: string, title: string, senderId: string, tagIds: Array<string>) {
	const database = connectDatabase(env.DATABASE)
	await database.insert(documents).values({
		id: documentId,
		title,
		senderId,
		storageObjectKey: `documents/${documentId}/original.pdf`,
		mimeType: "application/pdf",
		byteSize: 1024,
		status: "archived",
	})
	if (tagIds.length > 0) await database.insert(documentTags).values(tagIds.map((tagId) => ({ documentId, tagId })))
	await env.DOCUMENT_STORAGE.put(contentObjectKey(documentId), `# ${title}`)
}

async function prepareArchive() {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	await database.insert(senders).values([
		{ ...insurerAlias, normalizedName: "allianz versicherungs ag" },
		{ ...insurer, normalizedName: "allianz se", confirmedAt: new Date("2026-10-01T00:00:00Z") },
	])
	await database.insert(tags).values([
		{ ...taxAlias, normalizedName: "steuer" },
		{ ...taxYear, normalizedName: "tax 2026", confirmedAt: new Date("2026-10-01T00:00:00Z") },
	])
	await archive(policyId, "Allianz Household Insurance Policy", insurerAlias.id, [taxAlias.id])
	await archive(statementId, "Allianz Premium Statement 2026", insurer.id, [taxAlias.id, taxYear.id])
	await archive(contractId, "Allianz Liability Contract", insurer.id, [])
	const index = createInMemorySearchIndex()
	for (const documentId of [policyId, statementId, contractId]) {
		await indexDocument(database, env.DOCUMENT_STORAGE, index.searchIndex, documentId)
	}
	index.uploadedItemNames.length = 0
	return { database, ...index }
}

test("a merge moves every document and tag link to the target, and the backfill re-indexes only those documents", async () => {
	const { database, items, uploadedItemNames, searchIndex } = await prepareArchive()

	await mergeTaxonomyRecords(database, { kind: "sender", sourceRecordId: insurerAlias.id, targetRecordId: insurer.id })
	await mergeTaxonomyRecords(database, { kind: "tag", sourceRecordId: taxAlias.id, targetRecordId: taxYear.id })
	const report = await indexMissingDocuments(database, env.DOCUMENT_STORAGE, searchIndex)

	expect({
		senders: await database.select({ id: senders.id }).from(senders),
		tags: await database.select({ id: tags.id }).from(tags),
		documents: await database
			.select({ id: documents.id, senderId: documents.senderId })
			.from(documents)
			.orderBy(asc(documents.title)),
		links: await database.select().from(documentTags).orderBy(asc(documentTags.documentId)),
		reindexed: [...uploadedItemNames].sort(),
		report,
		indexedSenders: [...items.values()].map((item) => item.metadata.sender),
		policyHeading: items.get(`${policyId}.md`)?.content.split("\n").slice(0, 3),
	}).toEqual({
		senders: [{ id: insurer.id }],
		tags: [{ id: taxYear.id }],
		documents: [
			{ id: policyId, senderId: insurer.id },
			{ id: contractId, senderId: insurer.id },
			{ id: statementId, senderId: insurer.id },
		],
		links: [
			{ documentId: policyId, tagId: taxYear.id },
			{ documentId: statementId, tagId: taxYear.id },
		],
		reindexed: [`${policyId}.md`, `${statementId}.md`],
		report: { indexedDocumentIds: [policyId, statementId], failedDocuments: [], remainingDocumentCount: 0 },
		indexedSenders: [insurer.id, insurer.id, insurer.id],
		policyHeading: ["# Allianz Household Insurance Policy", "Sender: Allianz SE", "Tags: tax-2026"],
	})
})

test("a rename onto another record's name proposes merging into it, and an accepted rename confirms the record", async () => {
	const { database } = await prepareArchive()

	const outcomes = [
		await renameTaxonomyRecord(database, { kind: "sender", recordId: insurerAlias.id, name: "ALLIANZ SE." }),
		await renameTaxonomyRecord(database, {
			kind: "sender",
			recordId: insurerAlias.id,
			name: "Allianz Lebensversicherung",
		}),
	]

	expect({
		outcomes,
		senders: (
			await database
				.select({ name: senders.name, normalizedName: senders.normalizedName, confirmedAt: senders.confirmedAt })
				.from(senders)
				.orderBy(asc(senders.name))
		).map(({ confirmedAt, ...sender }) => ({ ...sender, confirmed: confirmedAt !== null })),
	}).toEqual({
		outcomes: [{ kind: "merge_proposed", targetRecord: insurer }, { kind: "renamed" }],
		senders: [
			{ name: "Allianz Lebensversicherung", normalizedName: "allianz lebensversicherung", confirmed: true },
			{ name: "Allianz SE", normalizedName: "allianz se", confirmed: true },
		],
	})
})

test("deleteTaxonomyRecord deletes a record no document refers to, confirmed or not, and refuses the others", async () => {
	const { database } = await prepareArchive()
	await database.delete(documentTags)
	const deletion = async (reference: Parameters<typeof deleteTaxonomyRecord>[1]) => {
		try {
			await deleteTaxonomyRecord(database, reference)
			return "deleted"
		} catch (error) {
			return error instanceof Error ? error.message : String(error)
		}
	}

	expect([
		await deletion({ kind: "sender", recordId: insurerAlias.id }),
		await deletion({ kind: "tag", recordId: taxAlias.id }),
		await deletion({ kind: "tag", recordId: taxAlias.id }),
		await deletion({ kind: "tag", recordId: taxYear.id }),
		await database.select({ id: tags.id }).from(tags),
	]).toEqual([`Documents still refer to the sender ${insurerAlias.id}`, "deleted", "deleted", "deleted", []])
})

test("a merge whose source no longer exists changes nothing and reports it", async () => {
	const { database } = await prepareArchive()
	const mergedTagId = "6f3b8d1e-4a2c-4e97-b051-9c7e2a5d8f16"

	const outcome = await mergeTaxonomyRecords(database, {
		kind: "tag",
		sourceRecordId: mergedTagId,
		targetRecordId: taxAlias.id,
	}).then(
		() => "merged",
		(error: unknown) => (error instanceof Error ? error.message : String(error)),
	)

	expect({
		outcome,
		target: await database
			.select({ id: tags.id, confirmedAt: tags.confirmedAt })
			.from(tags)
			.where(eq(tags.id, taxAlias.id)),
	}).toEqual({
		outcome: `The tag ${mergedTagId} to merge does not exist`,
		target: [{ id: taxAlias.id, confirmedAt: null }],
	})
})

test("a category merge flags a moved receipt without an amount when the target category requires one", async () => {
	const { database } = await prepareArchive()
	const slipCategoryId = "b8e2d4f6-1c3a-4d59-8e70-a2c4e6f8b013"
	const receiptCategoryId = "4c6e8a0b-2d4f-4a71-9c83-b5d7f9a1c325"
	await database.insert(categories).values([
		{ id: slipCategoryId, name: "Kassenbon", normalizedName: "kassenbon", expectedFields: [] },
		{
			id: receiptCategoryId,
			name: "Receipt",
			normalizedName: "receipt",
			expectedFields: ["amount", "currency"],
			confirmedAt: new Date("2026-10-01T00:00:00Z"),
		},
	])
	await database
		.update(documents)
		.set({ categoryId: slipCategoryId, documentDate: "2026-10-31" })
		.where(eq(documents.id, statementId))
	await database
		.update(documents)
		.set({ categoryId: slipCategoryId, documentDate: "2026-10-30" })
		.where(eq(documents.id, contractId))
	await database.insert(extractedFields).values({
		documentId: contractId,
		fieldKey: "amount",
		fieldType: "number",
		valueNumber: 12.4,
		confidenceScore: 0.9,
	})

	await mergeTaxonomyRecords(database, {
		kind: "category",
		sourceRecordId: slipCategoryId,
		targetRecordId: receiptCategoryId,
	})

	expect({
		reasons: await database
			.select({ id: documents.id, reason: documents.verificationReason })
			.from(documents)
			.where(eq(documents.categoryId, receiptCategoryId))
			.orderBy(asc(documents.title)),
		pending: (await listVerificationItems(database)).filter((item) => item.reason === "illegible_required_field"),
	}).toEqual({
		reasons: [
			{ id: contractId, reason: null },
			{ id: statementId, reason: "illegible_required_field" },
		],
		pending: [
			{
				reason: "illegible_required_field",
				createdAt: expect.any(Date),
				document: {
					id: statementId,
					status: "archived",
					mimeType: "application/pdf",
					title: "Allianz Premium Statement 2026",
					documentDate: "2026-10-31",
					senderName: "Allianz SE",
				},
				illegibleFields: [{ fieldKey: "amount", value: null }],
			},
		],
	})
})
