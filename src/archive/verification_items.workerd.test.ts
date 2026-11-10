import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { documents, senders } from "../database/schema"
import { countVerificationItems, listVerificationItems } from "./verification_items"

const telecomId = "b2f6d4a9-1e3c-4a75-9d82-7f0e5c3a1b64"
const policyId = "0d4f8b26-2e7a-4c91-8b35-6a1e9c3f7d52"
const receiptId = "9a3c6e18-5d4b-4f27-a960-3b8e1d7c5f04"
const termsId = "f1e7a3c5-8b2d-4c69-9e04-5d3a7b1f6c28"

const createdOn = (day: number) => new Date(`2026-11-0${day}T08:00:00Z`)

async function prepareArchive() {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	await database.insert(senders).values({ id: telecomId, name: "Nordkabel", normalizedName: "nordkabel" })
	const archived = { mimeType: "application/pdf", byteSize: 1024, status: "archived" as const }
	await database.insert(documents).values([
		{
			...archived,
			id: policyId,
			title: "Allianz Household Insurance Policy",
			documentDate: "2026-07-01",
			storageObjectKey: `documents/${policyId}/original.pdf`,
			createdAt: createdOn(2),
		},
		{
			...archived,
			id: receiptId,
			title: "Werkhof Receipt",
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
	return database
}

test("listVerificationItems gives each non-archival attachment and passes over an illegible field stored earlier", async () => {
	const database = await prepareArchive()

	expect({ items: await listVerificationItems(database), count: await countVerificationItems(database) }).toEqual({
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
		],
		count: 1,
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
