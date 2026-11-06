import { z } from "zod"

/** Each level grants every permission of the levels before it. */
const permissionLevels = ["read", "ingest", "modify", "administer"] as const

export type PermissionLevel = (typeof permissionLevels)[number]

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
	/** Mail from an allowed sender to the ingestion address. */
	| { kind: "inbound_mail"; senderAddress: string }

function grantedLevel(caller: Caller): PermissionLevel {
	switch (caller.kind) {
		// VISION.md trusts every member of the household with the whole archive.
		case "member_session":
			return "administer"
		case "api_token":
			return caller.scope.level
		case "inbound_mail":
			return "ingest"
	}
}

export function permits(caller: Caller, required: PermissionLevel): boolean {
	return permissionLevels.indexOf(grantedLevel(caller)) >= permissionLevels.indexOf(required)
}
