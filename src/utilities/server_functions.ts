import { createServerFn } from "@tanstack/react-start"
import { env } from "cloudflare:workers"
import { z } from "zod"
import { queryArchiveFacets } from "../archive/document_listing"
import { apiTokenIssuanceSchema, issueApiToken, listApiTokens, revokeApiToken } from "../authentication/api_tokens"
import { permits } from "../authorization/caller_authorization"
import { database } from "../database/client"
import { searchCriteriaSchema } from "../search/search_criteria"
import { searchDocuments } from "../search/document_search"
import type { Caller, PermissionLevel } from "../authorization/caller_authorization"

export const retrieveDocuments = createServerFn({ method: "GET" })
	.validator(searchCriteriaSchema)
	.handler(({ data }) => searchDocuments(database, env.SEARCH_INDEX, data))

export const listArchiveFacets = createServerFn({ method: "GET" }).handler(() => queryArchiveFacets(database))

// The Worker entry passes the caller to TanStack Start as request context. TanStack Start types a
// server function's context without the registered request context, so the caller is read through
// this one cast, and a request without a caller is refused.
function requirePermission(context: unknown, level: PermissionLevel): void {
	const caller = (context as { caller?: Caller } | undefined)?.caller
	if (caller === undefined || !permits(caller, level)) throw new Error(`This action requires the ${level} permission`)
}

export const listApiTokenRecords = createServerFn({ method: "GET" }).handler(({ context }) => {
	requirePermission(context, "administer")
	return listApiTokens(database)
})

export const issueApiTokenRecord = createServerFn({ method: "POST" })
	.validator(apiTokenIssuanceSchema)
	.handler(({ context, data }) => {
		requirePermission(context, "administer")
		return issueApiToken(database, data)
	})

export const revokeApiTokenRecord = createServerFn({ method: "POST" })
	.validator(z.strictObject({ tokenId: z.uuid() }))
	.handler(({ context, data }) => {
		requirePermission(context, "administer")
		return revokeApiToken(database, data.tokenId)
	})
