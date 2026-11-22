import type { PermissionLevel } from "../authorization/caller_authorization"

/**
 * The prefix of every route a bearer token reaches. Cloudflare Access bypasses it, and the Worker
 * admits only the exact routes below. Shared with the provisioning script.
 */
export const CLIENT_PATH_PREFIX = "/api/v1"

const DIGEST = "[0-9a-f]{64}"
const DOCUMENT_IDENTIFIER = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

export type DocumentRepresentationName = "original" | "text" | "thumbnail"

/** The request a client makes, with the parameters its path carries. */
type ClientRoute =
	| { kind: "authorization" }
	| { kind: "changes" }
	| { kind: "document_representation"; documentId: string; representation: DocumentRepresentationName }
	| { kind: "content_lookup" }
	| { kind: "content_submission"; sha256: string }
	| { kind: "document_status"; documentId: string }

/** The levels a route can require, each with the refusal of a token below it. */
export const levelRefusals = {
	read: "The API token does not permit reading the archive",
	ingest: "The API token does not permit ingesting documents",
} as const satisfies Partial<Record<PermissionLevel, string>>

export interface MatchedRoute {
	method: "GET" | "POST" | "PUT"
	level: keyof typeof levelRefusals
	/**
	 * What a token whose scope holds a list gets. A route that applies the scope answers only what
	 * the scope admits. A collector must see every content, or it would archive one a second time,
	 * so its routes cannot apply a scope and refuse such a token.
	 */
	restrictedScope: "applied" | "refused"
	route: ClientRoute
}

interface RouteDefinition extends Omit<MatchedRoute, "route"> {
	/** Anchored at both ends. request_dispatch.ts admits a path without Access only on a match. */
	pattern: RegExp
	route: (match: RegExpExecArray) => ClientRoute
}

export const clientRouteDefinitions: ReadonlyArray<RouteDefinition> = [
	// The lowest level, so every token can ask what it may do.
	{
		method: "GET",
		level: "ingest",
		restrictedScope: "applied",
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/authorization$`),
		route: () => ({ kind: "authorization" }),
	},
	{
		method: "GET",
		level: "read",
		restrictedScope: "applied",
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/changes$`),
		route: () => ({ kind: "changes" }),
	},
	{
		method: "GET",
		level: "read",
		restrictedScope: "applied",
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/documents/(${DOCUMENT_IDENTIFIER})/(original|text|thumbnail)$`),
		route: ([, documentId = "", representation]) => ({
			kind: "document_representation",
			documentId,
			representation: representation as DocumentRepresentationName,
		}),
	},
	{
		method: "POST",
		level: "ingest",
		restrictedScope: "refused",
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/contents/lookup$`),
		route: () => ({ kind: "content_lookup" }),
	},
	{
		method: "PUT",
		level: "ingest",
		restrictedScope: "refused",
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/contents/(${DIGEST})$`),
		route: ([, sha256 = ""]) => ({ kind: "content_submission", sha256 }),
	},
	{
		method: "GET",
		level: "ingest",
		restrictedScope: "refused",
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/documents/(${DOCUMENT_IDENTIFIER})$`),
		route: ([, documentId = ""]) => ({ kind: "document_status", documentId }),
	},
]

export function matchClientRoute(pathname: string): MatchedRoute | undefined {
	for (const { pattern, route, ...requirements } of clientRouteDefinitions) {
		const match = pattern.exec(pathname)
		if (match) return { ...requirements, route: route(match) }
	}
	return undefined
}

export function documentStatusPath(documentId: string): string {
	return `${CLIENT_PATH_PREFIX}/documents/${documentId}`
}
