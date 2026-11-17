/**
 * The prefix of every collector request. Cloudflare Access bypasses it, and the Worker admits
 * only the exact routes below with a bearer token. Shared with the provisioning script.
 */
export const COLLECTION_PATH_PREFIX = "/api/v1"

const DIGEST = "[0-9a-f]{64}"
const DOCUMENT_IDENTIFIER = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

/** The request a collector makes, with the parameter its path carries. */
export type CollectionRoute =
	| { kind: "content_lookup"; method: "POST" }
	| { kind: "content_submission"; method: "PUT"; sha256: string }
	| { kind: "document_status"; method: "GET"; documentId: string }

// Each pattern is anchored at both ends, so a subpath, a trailing slash, or uppercase hexadecimal
// matches nothing and stays behind Access.
const collectionRoutes: ReadonlyArray<{ pattern: RegExp; route: (parameter: string) => CollectionRoute }> = [
	{
		pattern: new RegExp(`^${COLLECTION_PATH_PREFIX}/contents/lookup$`),
		route: () => ({ kind: "content_lookup", method: "POST" }),
	},
	{
		pattern: new RegExp(`^${COLLECTION_PATH_PREFIX}/contents/(${DIGEST})$`),
		route: (sha256) => ({ kind: "content_submission", method: "PUT", sha256 }),
	},
	{
		pattern: new RegExp(`^${COLLECTION_PATH_PREFIX}/documents/(${DOCUMENT_IDENTIFIER})$`),
		route: (documentId) => ({ kind: "document_status", method: "GET", documentId }),
	},
]

export function matchCollectionRoute(pathname: string): CollectionRoute | undefined {
	for (const { pattern, route } of collectionRoutes) {
		const match = pattern.exec(pathname)
		if (match) return route(match[1] ?? "")
	}
	return undefined
}

export function documentStatusPath(documentId: string): string {
	return `${COLLECTION_PATH_PREFIX}/documents/${documentId}`
}
