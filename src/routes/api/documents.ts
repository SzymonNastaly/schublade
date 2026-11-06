import { createFileRoute } from "@tanstack/react-router"
import { env } from "cloudflare:workers"
import { queryDocumentListing } from "../../archive/document_listing"
import { database } from "../../database/client"
import { acceptDocumentUpload } from "../../ingestion/document_upload"
import type { UploadOutcome } from "../../ingestion/document_upload"

export const Route = createFileRoute("/api/documents")({
	server: {
		handlers: {
			GET: async () => Response.json({ documents: await queryDocumentListing(database) }),
			POST: async ({ request }) => {
				const formData = await request.formData()
				const files = formData.getAll("files").filter((entry) => entry instanceof File)
				if (files.length === 0) {
					return Response.json({ error: "Send the documents as multipart form fields named files" }, { status: 400 })
				}
				const outcomes: Array<UploadOutcome> = []
				for (const file of files) outcomes.push(await acceptDocumentUpload(env, file))
				return Response.json({ outcomes })
			},
		},
	},
})
