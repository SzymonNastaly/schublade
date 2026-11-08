import { eq } from "drizzle-orm"
import { z } from "zod"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { rasterizePage } from "../inference/page_rasterizer"
import { contentObjectKey, thumbnailObjectKey } from "../ingestion/source_file"

type RepresentationEnvironment = Pick<Env, "DATABASE" | "DOCUMENT_STORAGE">

const parametersSchema = z.object({
	documentId: z.uuid(),
	representation: z.enum(["original", "content", "thumbnail"]),
})

const ALWAYS_REVALIDATE = "private, no-store"
const THUMBNAIL_CACHE_CONTROL = "private, max-age=86400"
const THUMBNAIL_DOTS_PER_INCH = 40

const notFound = () => new Response("Not found", { status: 404 })

// The stored files are uploaded content served from the archive's own origin. nosniff keeps
// the browser on the stored type, and the sandbox denies a rendered file scripts and the origin.
const representationHeaders = (cacheControl: string) =>
	new Headers({
		"Content-Disposition": "inline",
		"Cache-Control": cacheControl,
		"X-Content-Type-Options": "nosniff",
		"Content-Security-Policy": "sandbox",
	})

function storedObjectResponse(object: R2ObjectBody, cacheControl: string): Response {
	const headers = representationHeaders(cacheControl)
	object.writeHttpMetadata(headers)
	return new Response(object.body, { headers })
}

async function readOriginalRecord(environment: RepresentationEnvironment, documentId: string) {
	const [document] = await connectDatabase(environment.DATABASE)
		.select({ storageObjectKey: documents.storageObjectKey, mimeType: documents.mimeType })
		.from(documents)
		.where(eq(documents.id, documentId))
	return document
}

/**
 * The first page of a PDF as a small image, rendered on first request and kept beside the file,
 * so existing documents need no backfill. Concurrent requests write the same object. An image
 * original is its own thumbnail.
 */
async function serveThumbnail(environment: RepresentationEnvironment, documentId: string): Promise<Response> {
	const key = thumbnailObjectKey(documentId)
	const stored = await environment.DOCUMENT_STORAGE.get(key)
	if (stored) return storedObjectResponse(stored, THUMBNAIL_CACHE_CONTROL)
	const document = await readOriginalRecord(environment, documentId)
	const original = document && (await environment.DOCUMENT_STORAGE.get(document.storageObjectKey))
	if (!document || !original) return notFound()
	if (document.mimeType !== "application/pdf") return storedObjectResponse(original, THUMBNAIL_CACHE_CONTROL)
	try {
		const { pngBytes } = await rasterizePage(new Uint8Array(await original.arrayBuffer()), 0, THUMBNAIL_DOTS_PER_INCH)
		await environment.DOCUMENT_STORAGE.put(key, pngBytes, { httpMetadata: { contentType: "image/png" } })
		const headers = representationHeaders(THUMBNAIL_CACHE_CONTROL)
		headers.set("Content-Type", "image/png")
		return new Response(new Uint8Array(pngBytes), { headers })
	} catch (error) {
		console.warn(`The thumbnail of document ${documentId} could not be rendered`, error)
		return notFound()
	}
}

/** Serves the original file, the extracted Markdown, or the thumbnail of a document from R2. */
export async function serveDocumentRepresentation(
	environment: RepresentationEnvironment,
	parameters: Record<string, string>,
): Promise<Response> {
	const parsed = parametersSchema.safeParse(parameters)
	if (!parsed.success) return notFound()
	const { documentId, representation } = parsed.data
	if (representation === "thumbnail") return serveThumbnail(environment, documentId)
	const key =
		representation === "content"
			? contentObjectKey(documentId)
			: (await readOriginalRecord(environment, documentId))?.storageObjectKey
	const object = key === undefined ? null : await environment.DOCUMENT_STORAGE.get(key)
	return object ? storedObjectResponse(object, ALWAYS_REVALIDATE) : notFound()
}
