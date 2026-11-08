import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { categories, documentTags, documents, extractedFields, senders, tags } from "../database/schema"
import { confirmTaxonomyRecord } from "./taxonomy_maintenance"
import { countVerificationItems, listVerificationItems } from "./verification_items"
import type { VerificationItem } from "./verification_items"

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
					status: "archived",
					mimeType: "application/pdf",
					title: "Nordkabel General Terms",
					documentDate: "2026-07-01",
					senderName: "Nordkabel",
				},
			},
			{
				reason: "illegible_required_field",
				createdAt: createdOn(3),
				document: {
					id: receiptId,
					status: "archived",
					mimeType: "application/pdf",
					title: "Werkhof Receipt",
					documentDate: null,
					senderName: null,
				},
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
						status: "archived",
						mimeType: "application/pdf",
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

test("listVerificationItems lists one tag on 150 documents and 121 unconfirmed records, more than D1 binds in one query", async () => {
	const database = await prepareArchive()
	await database.delete(documents)
	await database.delete(senders)
	const identifier = (prefix: string, index: number) => `${prefix}-0000-4000-8000-${String(index).padStart(12, "0")}`
	const senderIds = Array.from({ length: 120 }, (_, index) => identifier("5e2d0000", index))
	const documentIds = Array.from({ length: 150 }, (_, index) => identifier("d0c00000", index))
	// One statement per row, because a multi-row insert would bind more parameters than D1 allows.
	const statements = [
		...senderIds.map((id, index) =>
			database
				.insert(senders)
				.values({ id, name: `Sender ${index}`, normalizedName: `sender ${index}`, createdAt: createdOn(2) }),
		),
		...documentIds.flatMap((id, index) => [
			database.insert(documents).values({
				id,
				title: `Receipt ${index}`,
				senderId: senderIds[index % senderIds.length],
				categoryId: receiptCategoryId,
				storageObjectKey: `documents/${id}/original.jpg`,
				mimeType: "image/jpeg",
				byteSize: 2048,
				status: "archived",
				verificationReason: "illegible_required_field",
				createdAt: createdOn(3),
			}),
			database.insert(documentTags).values({ documentId: id, tagId }),
			database.insert(extractedFields).values({
				documentId: id,
				fieldKey: "amount",
				fieldType: "number",
				valueNumber: index,
				confidenceScore: 0.2,
			}),
		]),
	]
	const [firstStatement, ...laterStatements] = statements
	if (firstStatement) await database.batch([firstStatement, ...laterStatements])

	const items = await listVerificationItems(database)

	const receiptPhotograph = { status: "archived", mimeType: "image/jpeg", documentDate: null }
	const recordEntry = (name: string) =>
		items.find(
			(item): item is Extract<VerificationItem, { reason: "new_taxonomy_record" }> =>
				item.reason === "new_taxonomy_record" && item.record.name === name,
		)
	expect({
		count: await countVerificationItems(database),
		entries: items.reduce<Record<string, number>>(
			(tally, item) => ({ ...tally, [item.reason]: (tally[item.reason] ?? 0) + 1 }),
			{},
		),
		tagDocuments: recordEntry("steuer")?.documents.length,
		firstSender: recordEntry("Sender 0"),
		seventhReceipt: items.find((item) => item.reason !== "new_taxonomy_record" && item.document.id === documentIds[7]),
	}).toEqual({
		count: 271,
		entries: { illegible_required_field: 150, new_taxonomy_record: 121 },
		tagDocuments: 150,
		firstSender: {
			reason: "new_taxonomy_record",
			createdAt: createdOn(2),
			record: { kind: "sender", id: senderIds[0], name: "Sender 0" },
			documents: [
				{ ...receiptPhotograph, id: documentIds[0], title: "Receipt 0", senderName: "Sender 0" },
				{ ...receiptPhotograph, id: documentIds[120], title: "Receipt 120", senderName: "Sender 0" },
			],
		},
		seventhReceipt: {
			reason: "illegible_required_field",
			createdAt: createdOn(3),
			document: { ...receiptPhotograph, id: documentIds[7], title: "Receipt 7", senderName: "Sender 7" },
			illegibleFields: [
				{ fieldKey: "document_date", value: null },
				{ fieldKey: "amount", value: 7 },
			],
		},
	})
})

test("listVerificationItems and the count include each failed document, whose missing reason reads as a processing error", async () => {
	const database = await prepareArchive()
	const countBeforeFailures = await countVerificationItems(database)
	const failed = { mimeType: "image/png", byteSize: 1024, status: "failed" as const }
	const damagedId = "6b1f3d82-7c5e-4a90-b2d4-9e8a7c6f5d31"
	const legacyId = "d9e2c7a4-3f18-4b6d-9a05-1c7e4b8f2a63"
	await database.insert(documents).values([
		{
			...failed,
			id: damagedId,
			storageObjectKey: `documents/${damagedId}/original.png`,
			failureReason: "unreadable_file",
			createdAt: createdOn(6),
		},
		{ ...failed, id: legacyId, storageObjectKey: `documents/${legacyId}/original.png`, createdAt: createdOn(5) },
	])

	const items = await listVerificationItems(database)

	const failedDocument = (id: string) => ({
		id,
		status: "failed",
		mimeType: "image/png",
		title: null,
		documentDate: null,
		senderName: null,
	})
	expect({
		firstEntries: items.slice(0, 2),
		count: (await countVerificationItems(database)) - countBeforeFailures,
	}).toEqual({
		firstEntries: [
			{
				reason: "failed_ingestion",
				createdAt: createdOn(6),
				document: failedDocument(damagedId),
				failureReason: "unreadable_file",
			},
			{
				reason: "failed_ingestion",
				createdAt: createdOn(5),
				document: failedDocument(legacyId),
				failureReason: "processing_error",
			},
		],
		count: 2,
	})
})
