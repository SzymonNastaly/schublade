import { createFileRoute } from "@tanstack/react-router"
import { env } from "cloudflare:workers"
import { eq } from "drizzle-orm"
import { z } from "zod"
import { database } from "../../database/client"
import { documents } from "../../database/schema"
import { contentObjectKey } from "../../ingestion/source_file"

const parametersSchema = z.object({ documentId: z.uuid(), representation: z.enum(["original", "content"]) })

async function storageObjectKeyFor(documentId: string, representation: "original" | "content") {
	if (representation === "content") return contentObjectKey(documentId)
	const [document] = await database
		.select({ storageObjectKey: documents.storageObjectKey })
		.from(documents)
		.where(eq(documents.id, documentId))
	return document?.storageObjectKey
}

export const Route = createFileRoute("/api/documents/$documentId/$representation")({
	server: {
		handlers: {
			GET: async ({ params }) => {
				const parsed = parametersSchema.safeParse(params)
				if (!parsed.success) return new Response("Not found", { status: 404 })
				const key = await storageObjectKeyFor(parsed.data.documentId, parsed.data.representation)
				const object = key === undefined ? null : await env.DOCUMENT_STORAGE.get(key)
				if (!object) return new Response("Not found", { status: 404 })
				const headers = new Headers({ "Content-Disposition": "inline", "Cache-Control": "private, no-store" })
				object.writeHttpMetadata(headers)
				return new Response(object.body, { headers })
			},
		},
	},
})
