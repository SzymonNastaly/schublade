import { createFileRoute } from "@tanstack/react-router"
import { env } from "cloudflare:workers"
import { queryDocumentListing } from "../../archive/document_listing"
import { database } from "../../database/client"
import { receiveDocumentUploads } from "../../ingestion/document_upload"

export const Route = createFileRoute("/api/documents")({
	server: {
		handlers: {
			GET: async () => Response.json({ documents: await queryDocumentListing(database) }),
			POST: ({ request }) => receiveDocumentUploads(env, request),
		},
	},
})
