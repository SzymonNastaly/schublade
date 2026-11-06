import { eq } from "drizzle-orm"
import { z } from "zod"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { contentObjectKey } from "../ingestion/source_file"

type RepresentationEnvironment = Pick<Env, "DATABASE" | "DOCUMENT_STORAGE">

const parametersSchema = z.object({ documentId: z.uuid(), representation: z.enum(["original", "content"]) })

async function storageObjectKeyFor(
	environment: RepresentationEnvironment,
	documentId: string,
	representation: "original" | "content",
) {
	if (representation === "content") return contentObjectKey(documentId)
	const [document] = await connectDatabase(environment.DATABASE)
		.select({ storageObjectKey: documents.storageObjectKey })
		.from(documents)
		.where(eq(documents.id, documentId))
	return document?.storageObjectKey
}

/** Serves the original file or the extracted Markdown of a document from R2. */
export async function serveDocumentRepresentation(
	environment: RepresentationEnvironment,
	parameters: Record<string, string>,
): Promise<Response> {
	const parsed = parametersSchema.safeParse(parameters)
	if (!parsed.success) return new Response("Not found", { status: 404 })
	const key = await storageObjectKeyFor(environment, parsed.data.documentId, parsed.data.representation)
	const object = key === undefined ? null : await environment.DOCUMENT_STORAGE.get(key)
	if (!object) return new Response("Not found", { status: 404 })
	// The stored files are uploaded content served from the archive's own origin. nosniff keeps
	// the browser on the stored type, and the sandbox denies a rendered file scripts and the origin.
	const headers = new Headers({
		"Content-Disposition": "inline",
		"Cache-Control": "private, no-store",
		"X-Content-Type-Options": "nosniff",
		"Content-Security-Policy": "sandbox",
	})
	object.writeHttpMetadata(headers)
	return new Response(object.body, { headers })
}
