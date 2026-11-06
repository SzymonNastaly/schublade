import { applyD1Migrations, env, reset } from "cloudflare:test"
import { eq } from "drizzle-orm"
import { expect, inject, test, vi } from "vitest"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { contentObjectKey } from "../ingestion/source_file"
import { indexDocument, indexMissingDocuments, indexMissingDocumentsOnSchedule } from "./document_indexing"
import type { SearchIndex } from "./document_indexing"

const brokenDocumentId = "1c9e4a7b-2d3f-4e5a-8b6c-7d8e9f0a1b2c"
const intactDocumentId = "8f7e6d5c-4b3a-4291-8f0e-1d2c3b4a5968"

// Records uploads instead of calling the billed service, and lists the given pages of items.
function createSearchIndex(listedPages: Array<Array<Pick<AiSearchItemInfo, "key" | "status">>> = []) {
	const uploadedItemNames: Array<string> = []
	const searchIndex: SearchIndex = {
		search: () => Promise.reject(new Error("Indexing does not search")),
		items: {
			upload: (name) => {
				uploadedItemNames.push(name)
				return Promise.resolve({ id: name, key: name, status: "queued" })
			},
			list: (parameters) =>
				Promise.resolve({
					result: (listedPages[(parameters?.page ?? 1) - 1] ?? []).map((item) => ({ id: item.key, ...item })),
				}),
		},
	}
	return { uploadedItemNames, searchIndex }
}

async function archiveDocument(documentId: string, createdAt: Date, markdown?: string) {
	await connectDatabase(env.DATABASE)
		.insert(documents)
		.values({
			id: documentId,
			title: "Stromrechnung",
			storageObjectKey: `documents/${documentId}/original.pdf`,
			mimeType: "application/pdf",
			byteSize: 1024,
			status: "archived",
			createdAt,
			// The revision of the document's creation is current in the index once AI Search lists it.
			updatedAt: createdAt,
			indexedAt: createdAt,
		})
	if (markdown !== undefined) await env.DOCUMENT_STORAGE.put(contentObjectKey(documentId), markdown)
}

async function prepareArchive() {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	await archiveDocument(brokenDocumentId, new Date("2026-01-05T08:00:00Z"))
	await archiveDocument(intactDocumentId, new Date("2026-03-09T08:00:00Z"), "# Stromrechnung\n\nBetrag 72,09 €")
}

test("indexMissingDocuments indexes the other documents when one has no extracted Markdown", async () => {
	await prepareArchive()
	const { uploadedItemNames, searchIndex } = createSearchIndex()

	const report = await indexMissingDocuments(connectDatabase(env.DATABASE), env.DOCUMENT_STORAGE, searchIndex)

	expect({ report, uploadedItemNames }).toEqual({
		report: {
			indexedDocumentIds: [intactDocumentId],
			failedDocuments: [
				{
					documentId: brokenDocumentId,
					reason: `Document ${brokenDocumentId} has no extracted Markdown at documents/${brokenDocumentId}/content.md`,
				},
			],
			remainingDocumentCount: 1,
		},
		uploadedItemNames: [`${intactDocumentId}.md`],
	})
})

test("indexMissingDocuments reads every page of items until an empty one", async () => {
	await prepareArchive()
	const { uploadedItemNames, searchIndex } = createSearchIndex([
		[{ key: `${brokenDocumentId}.md`, status: "completed" }],
		[{ key: `${intactDocumentId}.md`, status: "completed" }],
	])

	const report = await indexMissingDocuments(connectDatabase(env.DATABASE), env.DOCUMENT_STORAGE, searchIndex)

	expect({ report, uploadedItemNames }).toEqual({
		report: { indexedDocumentIds: [], failedDocuments: [], remainingDocumentCount: 0 },
		uploadedItemNames: [],
	})
})

test("indexMissingDocuments uploads nothing when the item listing does not end", async () => {
	await prepareArchive()
	const { uploadedItemNames, searchIndex } = createSearchIndex(
		Array.from({ length: 101 }, () => [{ key: `${brokenDocumentId}.md`, status: "completed" as const }]),
	)

	const outcome = indexMissingDocuments(connectDatabase(env.DATABASE), env.DOCUMENT_STORAGE, searchIndex)

	await expect(outcome).rejects.toThrow(
		"AI Search listed more than 100 pages of items, so the documents it lacks are unknown",
	)
	expect(uploadedItemNames).toEqual([])
})

test("indexMissingDocumentsOnSchedule indexes a batch and logs one summary line", async () => {
	await prepareArchive()
	const { uploadedItemNames, searchIndex } = createSearchIndex()
	const log = vi.spyOn(console, "log").mockImplementation(() => undefined)

	await indexMissingDocumentsOnSchedule({ ...env, SEARCH_INDEX: searchIndex })

	expect({ uploadedItemNames, logLines: log.mock.calls }).toEqual({
		uploadedItemNames: [`${intactDocumentId}.md`],
		logLines: [
			[
				`Scheduled search indexing: 1 indexed, 1 failed, 1 remaining. ${brokenDocumentId}: Document ${brokenDocumentId} has no extracted Markdown at documents/${brokenDocumentId}/content.md`,
			],
		],
	})
	log.mockRestore()
})

test("indexMissingDocuments re-uploads a document changed since its item was uploaded, once", async () => {
	await prepareArchive()
	const database = connectDatabase(env.DATABASE)
	const revisedDocumentId = "5a0e3c9d-7b21-4f64-9c8e-2d4f6a1b3c75"
	// Archived, indexed, and revised within one second, as a member edits a document just archived.
	await archiveDocument(revisedDocumentId, new Date(), "# Wasserrechnung\n\nBetrag 41,30 €")
	const listedItems = [intactDocumentId, revisedDocumentId].map((documentId) => ({
		key: `${documentId}.md`,
		status: "completed" as const,
	}))
	const { uploadedItemNames, searchIndex } = createSearchIndex([listedItems])
	await indexDocument(database, env.DOCUMENT_STORAGE, searchIndex, intactDocumentId)
	await indexDocument(database, env.DOCUMENT_STORAGE, searchIndex, revisedDocumentId)
	await database.update(documents).set({ title: "Wasserrechnung 2026" }).where(eq(documents.id, revisedDocumentId))
	uploadedItemNames.length = 0

	const reports = [
		await indexMissingDocuments(database, env.DOCUMENT_STORAGE, searchIndex),
		await indexMissingDocuments(database, env.DOCUMENT_STORAGE, searchIndex),
	]

	expect({ reports, uploadedItemNames }).toEqual({
		reports: [
			{
				indexedDocumentIds: [revisedDocumentId],
				failedDocuments: [
					{
						documentId: brokenDocumentId,
						reason: `Document ${brokenDocumentId} has no extracted Markdown at documents/${brokenDocumentId}/content.md`,
					},
				],
				remainingDocumentCount: 1,
			},
			{
				indexedDocumentIds: [],
				failedDocuments: [
					{
						documentId: brokenDocumentId,
						reason: `Document ${brokenDocumentId} has no extracted Markdown at documents/${brokenDocumentId}/content.md`,
					},
				],
				remainingDocumentCount: 1,
			},
		],
		uploadedItemNames: [`${revisedDocumentId}.md`],
	})
})
