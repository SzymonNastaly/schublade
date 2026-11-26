import { eq } from "drizzle-orm"
import { z } from "zod"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { rasterizePage } from "../inference/page_rasterizer"
import {
	MAIL_MEDIA_TYPE,
	contentObjectKey,
	submittedThumbnailObjectKey,
	thumbnailObjectKey,
} from "../ingestion/source_file"

type RepresentationEnvironment = Pick<Env, "DATABASE" | "DOCUMENT_STORAGE">

const representationKinds = ["original", "content", "thumbnail"] as const

type RepresentationKind = (typeof representationKinds)[number]

const parametersSchema = z.object({
	documentId: z.uuid(),
	representation: z.enum(representationKinds),
})

const ALWAYS_REVALIDATE = "private, no-store"
const THUMBNAIL_CACHE_CONTROL = "private, max-age=86400"
const THUMBNAIL_DOTS_PER_INCH = 40
// A PDF whose first page could not be drawn keeps an empty object with this metadata where its
// thumbnail would be. Until the mark is a day old, a request reads the mark and not the original.
// After that the page is drawn again, so a failure that was not the file's does not last.
const UNRENDERABLE_MARK = { thumbnail: "unrenderable" }
const UNRENDERABLE_MARK_VALIDITY_MILLISECONDS = 24 * 60 * 60 * 1000

const notFound = () => new Response("Not found", { status: 404 })

/** The document row a representation is read for. */
interface RepresentedDocument {
	id: string
	storageObjectKey: string
	mimeType: string
}

/**
 * A representation as R2 holds it. The body is null when R2 found that the entity tag the
 * conditions name is current, so the caller answers 304.
 */
interface StoredRepresentation {
	metadata: R2Object
	body: ReadableStream | Uint8Array<ArrayBuffer> | null
}

// The stored files are uploaded content served from the archive's own origin. nosniff keeps
// the browser on the stored type, and the sandbox denies a rendered file scripts and the origin.
export const representationHeaders = (cacheControl: string) =>
	new Headers({
		"Content-Disposition": "inline",
		"Cache-Control": cacheControl,
		"X-Content-Type-Options": "nosniff",
		"Content-Security-Policy": "sandbox",
	})

function storedRepresentation(object: R2Object | R2ObjectBody | null): StoredRepresentation | undefined {
	if (object === null) return undefined
	return { metadata: object, body: "body" in object ? object.body : null }
}

/**
 * The first page as a small image: the JPEG its client drew and sent with it, or else one drawn
 * from a PDF on first request and kept beside the file, so existing documents need no backfill.
 * Concurrent requests write the same object. An image original is its own thumbnail. A page that
 * cannot be drawn is marked, so that asking for its thumbnail again does not read and draw the
 * whole original again.
 */
async function readThumbnail(
	storage: R2Bucket,
	document: RepresentedDocument,
	conditions: Headers | undefined,
): Promise<StoredRepresentation | undefined> {
	const submitted = await storage.get(submittedThumbnailObjectKey(document.id), { onlyIf: conditions })
	if (submitted) return storedRepresentation(submitted)
	const key = thumbnailObjectKey(document.id)
	const stored = await storage.get(key, { onlyIf: conditions })
	const marked = stored?.customMetadata?.thumbnail === UNRENDERABLE_MARK.thumbnail
	if (stored && !marked) return storedRepresentation(stored)
	if (stored && Date.now() - stored.uploaded.getTime() < UNRENDERABLE_MARK_VALIDITY_MILLISECONDS) return undefined
	// A message has no picture, and the row asks again once it is a PDF.
	if (document.mimeType === MAIL_MEDIA_TYPE) return undefined
	if (document.mimeType !== "application/pdf") {
		return storedRepresentation(await storage.get(document.storageObjectKey, { onlyIf: conditions }))
	}
	const original = await storage.get(document.storageObjectKey)
	if (!original) return undefined
	const originalBytes = new Uint8Array(await original.arrayBuffer())
	const rendered = await rasterizePage(originalBytes, 0, THUMBNAIL_DOTS_PER_INCH).catch((error: unknown) => {
		console.warn(`The thumbnail of document ${document.id} could not be rendered`, error)
		return undefined
	})
	if (!rendered) {
		await storage.put(key, "", { customMetadata: UNRENDERABLE_MARK })
		return undefined
	}
	const metadata = await storage.put(key, rendered.pngBytes, { httpMetadata: { contentType: "image/png" } })
	return { metadata, body: new Uint8Array(rendered.pngBytes) }
}

/**
 * Reads the original file, the extracted Markdown, or the thumbnail of a document from R2, or
 * undefined when it has none yet. Conditions such as If-None-Match go to R2, which then answers
 * without a body for a current entity tag.
 */
export async function readStoredRepresentation(
	storage: R2Bucket,
	document: RepresentedDocument,
	kind: RepresentationKind,
	conditions?: Headers,
): Promise<StoredRepresentation | undefined> {
	switch (kind) {
		case "original":
			return storedRepresentation(await storage.get(document.storageObjectKey, { onlyIf: conditions }))
		case "content":
			return storedRepresentation(await storage.get(contentObjectKey(document.id), { onlyIf: conditions }))
		case "thumbnail":
			return readThumbnail(storage, document, conditions)
	}
}

/** Serves a representation to a household member's browser. */
export async function serveDocumentRepresentation(
	environment: RepresentationEnvironment,
	parameters: Record<string, string>,
): Promise<Response> {
	const parsed = parametersSchema.safeParse(parameters)
	if (!parsed.success) return notFound()
	const { documentId, representation } = parsed.data
	const [document] = await connectDatabase(environment.DATABASE)
		.select({ id: documents.id, storageObjectKey: documents.storageObjectKey, mimeType: documents.mimeType })
		.from(documents)
		.where(eq(documents.id, documentId))
	const stored = document && (await readStoredRepresentation(environment.DOCUMENT_STORAGE, document, representation))
	if (!stored) return notFound()
	const headers = representationHeaders(representation === "thumbnail" ? THUMBNAIL_CACHE_CONTROL : ALWAYS_REVALIDATE)
	stored.metadata.writeHttpMetadata(headers)
	return new Response(stored.body, { headers })
}
