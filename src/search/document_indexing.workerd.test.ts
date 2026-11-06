import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { contentObjectKey } from "../ingestion/source_file"
import { indexMissingDocuments } from "./document_indexing"
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
