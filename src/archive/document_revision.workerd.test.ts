import { applyD1Migrations, env, reset } from "cloudflare:test"
import { asc, eq } from "drizzle-orm"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { categories, documentTags, documents, extractedFields, senders, tags } from "../database/schema"
import { contentObjectKey } from "../ingestion/source_file"
import { indexDocument } from "../search/document_indexing"
import { createInMemorySearchIndex } from "../search/in_memory_search_index"
import { deleteDocument, documentRevisionSchema, reviseDocument } from "./document_revision"

const receiptId = "6e2b9d41-3c7a-4f58-9b10-8a5d2e7c4f96"
const marketId = "1f8c3a5e-7d2b-4e69-a041-9b6d3c8e2f75"
const receiptCategoryId = "a4d1e7b3-2c9f-4a58-8e60-5b3f1d9c7a24"
const groceriesTagId = "d7a3c5e1-9b4f-4d26-8c13-6e0a2f8b4d59"

async function prepareReceipt() {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	await database.insert(senders).values({ id: marketId, name: "Frischemarkt", normalizedName: "frischemarkt" })
	await database.insert(categories).values({
		id: receiptCategoryId,
		name: "Receipt",
		normalizedName: "receipt",
		expectedFields: ["amount", "currency", "due_date", "iban", "invoice_number"],
		confirmedAt: new Date("2026-10-01T00:00:00Z"),
	})
	await database.insert(tags).values({ id: groceriesTagId, name: "groceries", normalizedName: "groceries" })
	await database.insert(documents).values({
		id: receiptId,
		title: "Frischemarkt Receipt October 2026",
		documentDate: "2026-10-31",
		senderId: marketId,
		categoryId: receiptCategoryId,
		storageObjectKey: `documents/${receiptId}/original.jpg`,
		mimeType: "image/jpeg",
		byteSize: 2048,
		status: "archived",
	})
	await database.insert(documentTags).values({ documentId: receiptId, tagId: groceriesTagId })
	await database.insert(extractedFields).values({
		documentId: receiptId,
		fieldKey: "invoice_number",
		fieldType: "text",
		valueText: "4471",
		confidenceScore: 0.9,
	})
	await env.DOCUMENT_STORAGE.put(`documents/${receiptId}/original.jpg`, "jpeg")
	await env.DOCUMENT_STORAGE.put(contentObjectKey(receiptId), "# Frischemarkt\n\nSUMME EUR ?9,63")
	const index = createInMemorySearchIndex()
	await indexDocument(database, env.DOCUMENT_STORAGE, index.searchIndex, receiptId)
	index.uploadedItemNames.length = 0
	return { database, ...index }
}

test("a revision stores each field a member enters without a confidence and uploads the document at once", async () => {
	const { database, uploadedItemNames, searchIndex } = await prepareReceipt()
	const environment = { database, storage: env.DOCUMENT_STORAGE, searchIndex }

	// The server function parses its input with documentRevisionSchema, which normalizes each field.
	const revise = (revision: unknown) => reviseDocument(environment, documentRevisionSchema.parse(revision))

	await revise({ documentId: receiptId, fields: { currency: "eur" } })
	await revise({ documentId: receiptId, fields: { amount: 29.63 } })

	expect({
		fields: await database
			.select({
				fieldKey: extractedFields.fieldKey,
				valueText: extractedFields.valueText,
				valueNumber: extractedFields.valueNumber,
				confidence: extractedFields.confidenceScore,
			})
			.from(extractedFields)
			.orderBy(asc(extractedFields.fieldKey)),
		uploadedItemNames,
	}).toEqual({
		fields: [
			{ fieldKey: "amount", valueText: null, valueNumber: 29.63, confidence: null },
			{ fieldKey: "currency", valueText: "EUR", valueNumber: null, confidence: null },
			{ fieldKey: "invoice_number", valueText: "4471", valueNumber: null, confidence: 0.9 },
		],
		uploadedItemNames: [`${receiptId}.md`, `${receiptId}.md`],
	})
})

test("a revision naming a new sender and tag creates confirmed records and re-indexes the document under them", async () => {
	const { database, items, searchIndex } = await prepareReceipt()

	await reviseDocument(
		{ database, storage: env.DOCUMENT_STORAGE, searchIndex },
		documentRevisionSchema.parse({
			documentId: receiptId,
			title: "Frischemarkt Talbrück Receipt",
			senderName: "Frischemarkt Talbrück GmbH",
			tagNames: ["Groceries", "household-2026"],
			personMemberId: null,
		}),
	)

	const [sender] = await database
		.select({ id: senders.id, confirmedAt: senders.confirmedAt })
		.from(senders)
		.where(eq(senders.normalizedName, "frischemarkt talbruck gmbh"))
	expect({
		senderConfirmed: sender?.confirmedAt !== null,
		tags: (
			await database.select({ name: tags.name, confirmedAt: tags.confirmedAt }).from(tags).orderBy(asc(tags.name))
		).map(({ name, confirmedAt }) => ({ name, confirmed: confirmedAt !== null })),
		linkedTags: (await database.select({ tagId: documentTags.tagId }).from(documentTags)).length,
		item: {
			heading: items.get(`${receiptId}.md`)?.content.split("\n").slice(0, 3),
			sender: items.get(`${receiptId}.md`)?.metadata.sender === sender?.id,
		},
	}).toEqual({
		senderConfirmed: true,
		tags: [
			{ name: "groceries", confirmed: true },
			{ name: "household-2026", confirmed: true },
		],
		linkedTags: 2,
		item: {
			heading: [
				"# Frischemarkt Talbrück Receipt",
				"Sender: Frischemarkt Talbrück GmbH",
				"Tags: groceries, household-2026",
			],
			sender: true,
		},
	})
})

test("deleteDocument removes the index item, every R2 object, and the rows of a document", async () => {
	const { database, items, searchIndex } = await prepareReceipt()

	await deleteDocument({ database, storage: env.DOCUMENT_STORAGE, searchIndex }, receiptId)

	expect({
		items: [...items.keys()],
		objects: (await env.DOCUMENT_STORAGE.list({ prefix: `documents/${receiptId}/` })).objects.length,
		documents: await database.select({ id: documents.id }).from(documents),
		fields: await database.select({ id: extractedFields.id }).from(extractedFields),
		links: await database.select().from(documentTags),
		tags: await database.select({ id: tags.id }).from(tags),
	}).toEqual({ items: [], objects: 0, documents: [], fields: [], links: [], tags: [{ id: groceriesTagId }] })
})

test("deleteDocument removes the index item from any page of the listing", async () => {
	const { database, items, searchIndex } = await prepareReceipt()
	const receiptItem = items.get(`${receiptId}.md`)
	items.clear()
	for (let index = 0; index < 50; index++) items.set(`other-${index}.md`, { content: "", metadata: {} })
	if (receiptItem) items.set(`${receiptId}.md`, receiptItem)

	await deleteDocument({ database, storage: env.DOCUMENT_STORAGE, searchIndex }, receiptId)

	expect({ receiptItem: items.has(`${receiptId}.md`), otherItems: items.size }).toEqual({
		receiptItem: false,
		otherItems: 50,
	})
})

test("deleteDocument leaves no index item when a backfill upload is accepted after its first removal", async () => {
	const index = await prepareReceipt()
	const { database, items, searchIndex } = index
	index.holdUploads(true)
	const backfillUpload = indexDocument(database, env.DOCUMENT_STORAGE, searchIndex, receiptId)
	const held = await index.nextHeldUpload()
	const searchItems = await searchIndex.items
	let removals = 0
	const deletingSearchIndex = {
		...searchIndex,
		items: {
			...searchItems,
			// AI Search accepts the backfill's upload right after the first removal of the item.
			delete: async (itemId: string) => {
				await searchItems.delete(itemId)
				if (++removals > 1) return
				held.accept()
				held.release()
			},
		},
	}

	await deleteDocument({ database, storage: env.DOCUMENT_STORAGE, searchIndex: deletingSearchIndex }, receiptId)
	await backfillUpload

	expect({ items: [...items.keys()], documents: await database.select({ id: documents.id }).from(documents) }).toEqual({
		items: [],
		documents: [],
	})
})

test("a backfill upload accepted after deleteDocument finished removes the item it created", async () => {
	const index = await prepareReceipt()
	const { database, items, searchIndex } = index
	index.holdUploads(true)
	const backfillUpload = indexDocument(database, env.DOCUMENT_STORAGE, searchIndex, receiptId)
	const held = await index.nextHeldUpload()

	await deleteDocument({ database, storage: env.DOCUMENT_STORAGE, searchIndex }, receiptId)
	const itemsAfterDeletion = [...items.keys()]
	held.accept()
	held.release()
	await backfillUpload

	expect({ itemsAfterDeletion, itemsAfterUpload: [...items.keys()] }).toEqual({
		itemsAfterDeletion: [],
		itemsAfterUpload: [],
	})
})

test("a revision naming an existing unconfirmed sender, category, and tag confirms each of them", async () => {
	const { database, searchIndex } = await prepareReceipt()
	await database.insert(senders).values({ name: "Werkhof", normalizedName: "werkhof" })
	await database.insert(categories).values({ name: "Kassenbon", normalizedName: "kassenbon", expectedFields: [] })

	await reviseDocument(
		{ database, storage: env.DOCUMENT_STORAGE, searchIndex },
		documentRevisionSchema.parse({
			documentId: receiptId,
			senderName: "Werkhof",
			categoryName: "Kassenbon",
			tagNames: ["groceries"],
		}),
	)

	const confirmation = async (table: typeof senders | typeof categories | typeof tags) =>
		(
			await database.select({ name: table.name, confirmedAt: table.confirmedAt }).from(table).orderBy(asc(table.name))
		).map(({ name, confirmedAt }) => ({ name, confirmed: confirmedAt !== null }))
	expect({
		senders: await confirmation(senders),
		categories: await confirmation(categories),
		tags: await confirmation(tags),
	}).toEqual({
		senders: [
			{ name: "Frischemarkt", confirmed: false },
			{ name: "Werkhof", confirmed: true },
		],
		categories: [
			{ name: "Kassenbon", confirmed: true },
			{ name: "Receipt", confirmed: true },
		],
		tags: [{ name: "groceries", confirmed: true }],
	})
})
