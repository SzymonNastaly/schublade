import { z } from "zod"

/** Each level grants every permission of the levels before it. */
const permissionLevels = ["read", "ingest", "modify", "administer"] as const

export type PermissionLevel = (typeof permissionLevels)[number]

/** The lists hold record identifiers, so renaming a record leaves a scope intact. */
export const authorizationScopeSchema = z.strictObject({
	level: z.enum(permissionLevels),
	allowedCategories: z.array(z.string()).optional(),
	allowedTags: z.array(z.string()).optional(),
	deniedTags: z.array(z.string()).optional(),
	allowedSenders: z.array(z.string()).optional(),
})

export type AuthorizationScope = z.infer<typeof authorizationScopeSchema>

/** The party behind a request or a message, established once at the Worker entry. */
export type Caller =
	/** A household member signed in through Cloudflare Access. */
	| { kind: "member_session" }
	| { kind: "api_token"; tokenId: string; scope: AuthorizationScope }
	/** A client that a household member authorized through the consent page of /mcp. */
	| { kind: "oauth_grant"; scope: AuthorizationScope }
	/** Mail from an allowed sender to the ingestion address. */
	| { kind: "inbound_mail"; senderAddress: string }

function grantedLevel(caller: Caller): PermissionLevel {
	switch (caller.kind) {
		// VISION.md trusts every member of the household with the whole archive.
		case "member_session":
			return "administer"
		case "api_token":
		case "oauth_grant":
			return caller.scope.level
		case "inbound_mail":
			return "ingest"
	}
}

export function permits(caller: Caller, required: PermissionLevel): boolean {
	return permissionLevels.indexOf(grantedLevel(caller)) >= permissionLevels.indexOf(required)
}

/** The level each server function requires. VISION.md reserves merging and deleting for administer. */
const operationLevels = {
	readArchive: "read",
	reviseDocument: "modify",
	retryDocumentIngestion: "modify",
	renameTaxonomyRecord: "modify",
	mergeTaxonomyRecords: "administer",
	deleteDocument: "administer",
	deleteTaxonomyRecord: "administer",
	administerApiTokens: "administer",
	administerAuthorizationGrants: "administer",
} as const satisfies Record<string, PermissionLevel>

type ArchiveOperation = keyof typeof operationLevels

/**
 * Refuses a server function call whose caller lacks the operation's level. The Worker entry
 * passes the caller to TanStack Start as request context, which types a server function's
 * context without it, so the caller is read from the untyped context, and a call without one
 * is refused.
 */
export function authorizeOperation(context: unknown, operation: ArchiveOperation): void {
	const caller = (context as { caller?: Caller } | undefined)?.caller
	const level = operationLevels[operation]
	if (caller === undefined || !permits(caller, level)) throw new Error(`This action requires the ${level} permission`)
}
