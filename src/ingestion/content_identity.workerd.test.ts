import { applyD1Migrations, env, reset } from "cloudflare:test"
import { asc } from "drizzle-orm"
import { expect, inject, test, vi } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { connectDatabase } from "../database/client"
import { contents, documents } from "../database/schema"
import { recordMissingContentDigests } from "./content_identity"

const digestedId = "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
const withoutOriginalId = "8b2c3d4e-5f60-4b7c-9d8e-0f1a2b3c4d5e"
const awaitingRenderingId = "9c3d4e5f-6071-4c8d-ae9f-1a2b3c4d5e6f"
const SCANNED_INVOICE_SHA256 = "3551f8806c62a6b604bfbeab63ececeac46ee9df4e7db1ff5835377ff07ab0ed"

test("the backfill digests a document archived before digests existed, keeps its revision, and skips one without an original", async () => {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	await database.insert(documents).values([
		{
			id: digestedId,
			storageObjectKey: `documents/${digestedId}/original.pdf`,
			mimeType: "application/pdf",
			byteSize: scannedInvoice.byteLength,
			status: "archived",
			createdAt: new Date(1793100000_000),
			updatedAt: new Date(1793100000_000),
		},
		{
			id: withoutOriginalId,
			storageObjectKey: `documents/${withoutOriginalId}/original.jpg`,
			mimeType: "image/jpeg",
			byteSize: 2048,
			status: "archived",
			createdAt: new Date(1793100100_000),
			updatedAt: new Date(1793100100_000),
		},
		{
			id: awaitingRenderingId,
			storageObjectKey: `documents/${awaitingRenderingId}/original.eml`,
			mimeType: "message/rfc822",
			byteSize: 4096,
			status: "awaiting_rendering",
			createdAt: new Date(1793100200_000),
			updatedAt: new Date(1793100200_000),
		},
	])
	await env.DOCUMENT_STORAGE.put(`documents/${digestedId}/original.pdf`, scannedInvoice)
	const warnings: Array<string> = []
	const warn = vi.spyOn(console, "warn").mockImplementation((message: unknown) => warnings.push(String(message)))

	const report = await recordMissingContentDigests(database, env.DOCUMENT_STORAGE)

	warn.mockRestore()
	expect({
		report,
		warnings,
		documents: await database
			.select({ id: documents.id, originalSha256: documents.originalSha256, updatedAt: documents.updatedAt })
			.from(documents)
			.orderBy(asc(documents.createdAt)),
		contents: await database.select({ sha256: contents.sha256, documentId: contents.documentId }).from(contents),
	}).toEqual({
		report: {
			recordedDocumentIds: [digestedId],
			missingOriginalDocumentIds: [withoutOriginalId],
			failedDocumentIds: [],
			remainingDocumentCount: 1,
		},
		warnings: [
			`Document ${withoutOriginalId} has no original at documents/${withoutOriginalId}/original.jpg, so its digest cannot be recorded`,
		],
		documents: [
			{ id: digestedId, originalSha256: SCANNED_INVOICE_SHA256, updatedAt: new Date(1793100000_000) },
			{ id: withoutOriginalId, originalSha256: null, updatedAt: new Date(1793100100_000) },
			{ id: awaitingRenderingId, originalSha256: null, updatedAt: new Date(1793100200_000) },
		],
		contents: [{ sha256: SCANNED_INVOICE_SHA256, documentId: digestedId }],
	})
})

test("the backfill passes over a full batch of documents without an original and one whose read fails", async () => {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	const withoutOriginalIds = Array.from(
		{ length: 25 },
		(_, index) => `00000000-0000-4000-8000-${index.toString().padStart(12, "0")}`,
	)
	const unreadableId = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
	// D1 binds at most 100 parameters per statement, so each row is its own insert.
	const rows = [
		...withoutOriginalIds.map((id) => ({
			id,
			storageObjectKey: `documents/${id}/original.pdf`,
			mimeType: "application/pdf",
			byteSize: 1024,
			createdAt: new Date(1793000000_000),
		})),
		{
			id: unreadableId,
			storageObjectKey: `documents/${unreadableId}/original.pdf`,
			mimeType: "application/pdf",
			byteSize: 1024,
			createdAt: new Date(1793000100_000),
		},
		{
			id: digestedId,
			storageObjectKey: `documents/${digestedId}/original.pdf`,
			mimeType: "application/pdf",
			byteSize: scannedInvoice.byteLength,
			createdAt: new Date(1793000200_000),
		},
	]
	for (const row of rows) await database.insert(documents).values({ ...row, status: "archived" })
	await env.DOCUMENT_STORAGE.put(`documents/${digestedId}/original.pdf`, scannedInvoice)
	const storage = {
		get: (key: string) =>
			key === `documents/${unreadableId}/original.pdf`
				? Promise.reject(new Error("R2 is unavailable"))
				: env.DOCUMENT_STORAGE.get(key),
	}
	const errors: Array<string> = []
	const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined)
	const error = vi.spyOn(console, "error").mockImplementation((message: unknown) => errors.push(String(message)))

	const report = await recordMissingContentDigests(database, storage as unknown as R2Bucket)

	warn.mockRestore()
	error.mockRestore()
	expect({ report, errors }).toEqual({
		report: {
			recordedDocumentIds: [digestedId],
			missingOriginalDocumentIds: withoutOriginalIds,
			failedDocumentIds: [unreadableId],
			remainingDocumentCount: 26,
		},
		errors: [`Recording the digest of document ${unreadableId} failed`],
	})
})
