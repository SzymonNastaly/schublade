import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { categories, documents, extractedFields, senders, tags } from "../database/schema"
import { confirmTaxonomyRecord } from "./taxonomy_maintenance"
import { countVerificationItems, listVerificationItems } from "./verification_items"

const insurerId = "5c8e2a17-4b9d-4f30-8e61-2a7c9d4b1e86"
const telecomId = "b2f6d4a9-1e3c-4a75-9d82-7f0e5c3a1b64"
const receiptCategoryId = "3a9d7f25-6c1e-4b48-a093-8e2b5d7f1c40"
const tagId = "e5b1c9d3-7a2f-4e64-b815-0c4a8e6d2f97"
const policyId = "0d4f8b26-2e7a-4c91-8b35-6a1e9c3f7d52"
const receiptId = "9a3c6e18-5d4b-4f27-a960-3b8e1d7c5f04"
const termsId = "f1e7a3c5-8b2d-4c69-9e04-5d3a7b1f6c28"

const createdOn = (day: number) => new Date(`2026-11-0${day}T08:00:00Z`)

async function prepareArchive() {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	await database.insert(tags).values({ id: tagId, name: "steuer", normalizedName: "steuer", createdAt: createdOn(1) })
	await database.insert(senders).values([
		{ id: insurerId, name: "Allianz SE", normalizedName: "allianz se", createdAt: createdOn(2) },
		{ id: telecomId, name: "Nordkabel", normalizedName: "nordkabel", confirmedAt: createdOn(1) },
	])
	await database.insert(categories).values({
		id: receiptCategoryId,
		name: "Receipt",
		normalizedName: "receipt",
		expectedFields: ["amount", "currency"],
		confirmedAt: createdOn(1),
	})
	const archived = { mimeType: "application/pdf", byteSize: 1024, status: "archived" as const }
	await database.insert(documents).values([
		{
			...archived,
			id: policyId,
			title: "Allianz Household Insurance Policy",
			documentDate: "2026-07-01",
			senderId: insurerId,
			storageObjectKey: `documents/${policyId}/original.pdf`,
			createdAt: createdOn(2),
		},
		{
			...archived,
			id: receiptId,
			title: "Werkhof Receipt",
			categoryId: receiptCategoryId,
			storageObjectKey: `documents/${receiptId}/original.pdf`,
			verificationReason: "illegible_required_field",
			createdAt: createdOn(3),
		},
		{
			...archived,
			id: termsId,
			title: "Nordkabel General Terms",
			documentDate: "2026-07-01",
			senderId: telecomId,
			storageObjectKey: `documents/${termsId}/original.pdf`,
			verificationReason: "non_archival_attachment",
			createdAt: createdOn(4),
		},
	])
	await database.insert(extractedFields).values({
		documentId: receiptId,
		fieldKey: "amount",
		fieldType: "number",
		valueNumber: 75.49,
		confidenceScore: 0.3,
	})
	return database
}

test("listVerificationItems gives each unconfirmed record with its documents and each flagged document, newest first", async () => {
	const database = await prepareArchive()

	const items = await listVerificationItems(database)
	const count = await countVerificationItems(database)
	await confirmTaxonomyRecord(database, { kind: "sender", recordId: insurerId })

	expect({ items, count, countAfterConfirmation: await countVerificationItems(database) }).toEqual({
		items: [
			{
				reason: "non_archival_attachment",
				createdAt: createdOn(4),
				document: {
					id: termsId,
					title: "Nordkabel General Terms",
					documentDate: "2026-07-01",
					senderName: "Nordkabel",
				},
			},
			{
				reason: "illegible_required_field",
				createdAt: createdOn(3),
				document: { id: receiptId, title: "Werkhof Receipt", documentDate: null, senderName: null },
				illegibleFields: [
					{ fieldKey: "document_date", value: null },
					{ fieldKey: "amount", value: 75.49 },
				],
			},
			{
				reason: "new_taxonomy_record",
				createdAt: createdOn(2),
				record: { kind: "sender", id: insurerId, name: "Allianz SE" },
				documents: [
					{
						id: policyId,
						title: "Allianz Household Insurance Policy",
						documentDate: "2026-07-01",
						senderName: "Allianz SE",
					},
				],
			},
			{
				reason: "new_taxonomy_record",
				createdAt: createdOn(1),
				record: { kind: "tag", id: tagId, name: "steuer" },
				documents: [],
			},
		],
		count: 4,
		countAfterConfirmation: 3,
	})
})
