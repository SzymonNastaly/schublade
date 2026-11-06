import { createFileRoute } from "@tanstack/react-router"
import { env } from "cloudflare:workers"
import { database } from "../../database/client"
import { indexMissingDocuments } from "../../search/document_indexing"

export const Route = createFileRoute("/api/search_index")({
	server: {
		handlers: {
			// Indexes archived documents that AI Search lacks, such as those archived before the
			// workflow indexed documents. Repeat while a call indexes documents and
			// remainingDocumentCount is above 0. failedDocuments names those it could not upload.
			POST: async () => Response.json(await indexMissingDocuments(database, env.DOCUMENT_STORAGE, env.SEARCH_INDEX)),
		},
	},
})
