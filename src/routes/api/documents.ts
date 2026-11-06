import { createFileRoute } from "@tanstack/react-router"
import { env } from "cloudflare:workers"
import { z } from "zod"
import { database } from "../../database/client"
import { receiveDocumentUploads } from "../../ingestion/document_upload"
import { searchCriteriaSchema } from "../../search/search_criteria"
import { searchDocuments } from "../../search/document_search"

export const Route = createFileRoute("/api/documents")({
	server: {
		handlers: {
			// Without parameters, GET lists every document. `query` searches, and the other
			// parameters of searchCriteriaSchema filter. An empty parameter is ignored.
			GET: async ({ request }) => {
				const parameters = [...new URL(request.url).searchParams].filter(([, value]) => value !== "")
				const criteria = searchCriteriaSchema.safeParse(Object.fromEntries(parameters))
				if (!criteria.success) return Response.json({ error: z.prettifyError(criteria.error) }, { status: 400 })
				return Response.json({ documents: await searchDocuments(database, env.SEARCH_INDEX, criteria.data) })
			},
			POST: ({ request }) => receiveDocumentUploads(env, request),
		},
	},
})
