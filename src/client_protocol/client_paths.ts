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
	route: ClientRoute
}

interface RouteDefinition extends Omit<MatchedRoute, "route"> {
	/** Anchored at both ends. request_dispatch.ts admits a path without Access only on a match. */
	pattern: RegExp
	route: (match: RegExpExecArray) => ClientRoute
}

const routeDefinitions: ReadonlyArray<RouteDefinition> = [
	{
		method: "GET",
		level: "read",
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/authorization$`),
		route: () => ({ kind: "authorization" }),
	},
	{
		method: "GET",
		level: "read",
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/changes$`),
		route: () => ({ kind: "changes" }),
	},
	{
		method: "GET",
		level: "read",
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
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/contents/lookup$`),
		route: () => ({ kind: "content_lookup" }),
	},
	{
		method: "PUT",
		level: "ingest",
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/contents/(${DIGEST})$`),
		route: ([, sha256 = ""]) => ({ kind: "content_submission", sha256 }),
	},
	{
		method: "GET",
		level: "ingest",
		pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/documents/(${DOCUMENT_IDENTIFIER})$`),
		route: ([, documentId = ""]) => ({ kind: "document_status", documentId }),
	},
]

export function matchClientRoute(pathname: string): MatchedRoute | undefined {
	for (const { pattern, route, ...requirements } of routeDefinitions) {
		const match = pattern.exec(pathname)
		if (match) return { ...requirements, route: route(match) }
	}
	return undefined
}

export function documentStatusPath(documentId: string): string {
	return `${CLIENT_PATH_PREFIX}/documents/${documentId}`
}
