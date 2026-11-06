import { applyD1Migrations, env } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { searchDocuments } from "./document_search"
import type { SearchIndex } from "./document_indexing"

const heatingStatementId = "3a4b5c6d-7e8f-4a0b-9c1d-2e3f4a5b6c7d"
const waterInvoiceId = "4b5c6d7e-8f9a-4b1c-8d2e-3f4a5b6c7d8e"
const gasInvoiceId = "5c6d7e8f-9a0b-4c2d-9e3f-4a5b6c7d8e9f"

// Answers like AI Search: the best chunks of the whole index, at most max_num_results of them.
// The heating statement is long, so its 30 chunks outrank the single chunk of each invoice.
const rankedChunks = [
	...Array.from({ length: 30 }, (_, index) => ({
		id: `${heatingStatementId}-${index}`,
		type: "text",
		score: 0.9 - index * 0.001,
		text: `Heizkostenabrechnung Stadtwerke Talbrück, Abschnitt ${index + 1}`,
		item: { key: `${heatingStatementId}.md` },
	})),
	{
		id: waterInvoiceId,
		type: "text",
		score: 0.6,
		text: "Wasser Stadtwerke Talbrück",
		item: { key: `${waterInvoiceId}.md` },
	},
	{ id: gasInvoiceId, type: "text", score: 0.5, text: "Gas Stadtwerke Talbrück", item: { key: `${gasInvoiceId}.md` } },
]
const searchIndex: SearchIndex = {
	search: (request) =>
		Promise.resolve({
			search_query: request.query ?? "",
			chunks: rankedChunks.slice(0, request.ai_search_options?.retrieval?.max_num_results),
		}),
	items: {
		upload: () => Promise.reject(new Error("Search does not upload")),
		list: () => Promise.resolve({ result: [] }),
	},
}

test("searchDocuments returns every matching document when one document has many matching chunks", async () => {
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	await database.insert(documents).values(
		[heatingStatementId, waterInvoiceId, gasInvoiceId].map((id) => ({
			id,
			storageObjectKey: `documents/${id}/original.pdf`,
			mimeType: "application/pdf",
			byteSize: 1024,
			status: "archived" as const,
		})),
	)

	const results = await searchDocuments(database, searchIndex, { query: "Stadtwerke Talbrück" })

	expect(results.map((document) => document.id)).toEqual([heatingStatementId, waterInvoiceId, gasInvoiceId])
})
