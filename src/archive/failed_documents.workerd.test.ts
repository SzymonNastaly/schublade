import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { countFailedDocuments, listFailedDocuments } from "./failed_documents"

const createdOn = (day: number) => new Date(`2026-11-0${day}T08:00:00Z`)

test("listFailedDocuments and the count give each failed document, newest first, whose missing reason reads as a processing error", async () => {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	const policyId = "0d4f8b26-2e7a-4c91-8b35-6a1e9c3f7d52"
	const damagedId = "6b1f3d82-7c5e-4a90-b2d4-9e8a7c6f5d31"
	const legacyId = "d9e2c7a4-3f18-4b6d-9a05-1c7e4b8f2a63"
	const failed = { mimeType: "image/png", byteSize: 1024, status: "failed" as const }
	await database.insert(documents).values([
		{
			id: policyId,
			title: "Allianz Household Insurance Policy",
			storageObjectKey: `documents/${policyId}/original.pdf`,
			mimeType: "application/pdf",
			byteSize: 1024,
			status: "archived",
			createdAt: createdOn(7),
		},
		{
			...failed,
			id: damagedId,
			title: "Water Meter Reading",
			storageObjectKey: `documents/${damagedId}/original.png`,
			failureReason: "unreadable_file",
			createdAt: createdOn(6),
		},
		{ ...failed, id: legacyId, storageObjectKey: `documents/${legacyId}/original.png`, createdAt: createdOn(5) },
	])

	expect({ failedDocuments: await listFailedDocuments(database), count: await countFailedDocuments(database) }).toEqual(
		{
			failedDocuments: [
				{ id: damagedId, title: "Water Meter Reading", failureReason: "unreadable_file" },
				{ id: legacyId, title: null, failureReason: "processing_error" },
			],
			count: 2,
		},
	)
})
