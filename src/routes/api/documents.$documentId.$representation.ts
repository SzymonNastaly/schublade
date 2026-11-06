import { createFileRoute } from "@tanstack/react-router"
import { env } from "cloudflare:workers"
import { serveDocumentRepresentation } from "../../archive/document_representation"

export const Route = createFileRoute("/api/documents/$documentId/$representation")({
	server: {
		handlers: {
			GET: ({ params }) => serveDocumentRepresentation(env, params),
		},
	},
})
