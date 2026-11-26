import { eq } from "drizzle-orm"
import { z } from "zod"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { contentObjectKey, parseSourceFile, submittedThumbnailObjectKey } from "../ingestion/source_file"

type RepresentationEnvironment = Pick<Env, "DATABASE" | "DOCUMENT_STORAGE">

const representationKinds = ["original", "content", "thumbnail"] as const

type RepresentationKind = (typeof representationKinds)[number]

const parametersSchema = z.object({
	documentId: z.uuid(),
	representation: z.enum(representationKinds),
})

const ALWAYS_REVALIDATE = "private, no-store"
const THUMBNAIL_CACHE_CONTROL = "private, max-age=86400"

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
	body: ReadableStream | null
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
 * The first page as a small image: the JPEG its client drew and sent with it, or the original
 * when it is a picture. The Worker draws no page itself, so a PDF that arrived without one has none.
 */
async function readThumbnail(
	storage: R2Bucket,
	document: RepresentedDocument,
	conditions: Headers | undefined,
): Promise<StoredRepresentation | undefined> {
	const submitted = await storage.get(submittedThumbnailObjectKey(document.id), { onlyIf: conditions })
	if (submitted) return storedRepresentation(submitted)
	if (parseSourceFile(document.mimeType)?.kind !== "image") return undefined
	return storedRepresentation(await storage.get(document.storageObjectKey, { onlyIf: conditions }))
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
