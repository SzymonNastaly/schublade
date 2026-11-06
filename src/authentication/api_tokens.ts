import { desc, eq } from "drizzle-orm"
import { z } from "zod"
import { apiTokens } from "../database/schema"
import type { ArchiveDatabase } from "../database/client"
import type { Caller, PermissionLevel } from "../authorization/caller_authorization"

// The prefix makes a leaked token recognizable to secret scanners and to the person who finds it.
const TOKEN_PREFIX = "schublade_"
const TOKEN_RANDOM_BYTES = 32
const tokenPattern = /^schublade_[A-Za-z0-9_-]{43}$/
const bearerPattern = /^Bearer +(\S+)$/i

// Recording every use would write to D1 on each upload, so a use within the hour is not recorded.
const LAST_USE_RECORDING_INTERVAL_MILLISECONDS = 60 * 60 * 1000

/** Members can issue only ingestion tokens until the operations that need the other levels exist. */
const issuableLevels = ["ingest"] as const satisfies ReadonlyArray<PermissionLevel>

export const apiTokenIssuanceSchema = z.strictObject({
	description: z.string().trim().min(1).max(200),
	level: z.enum(issuableLevels),
})

export interface ApiTokenListing {
	id: string
	description: string
	level: PermissionLevel
	createdAt: Date
	lastUsedAt: Date | null
}

function encodeBase64Url(bytes: Uint8Array): string {
	return btoa(String.fromCharCode(...bytes))
		.replaceAll("+", "-")
		.replaceAll("/", "_")
		.replace(/=+$/, "")
}

async function digestToken(token: string): Promise<string> {
	const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)))
	return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("")
}

/** Stores only the digest, so the returned token is the one and only time the caller sees it. */
export async function issueApiToken(
	database: ArchiveDatabase,
	issuance: z.infer<typeof apiTokenIssuanceSchema>,
): Promise<{ token: string; listing: ApiTokenListing }> {
	const token = TOKEN_PREFIX + encodeBase64Url(crypto.getRandomValues(new Uint8Array(TOKEN_RANDOM_BYTES)))
	const [record] = await database
		.insert(apiTokens)
		.values({
			description: issuance.description,
			tokenSha256: await digestToken(token),
			authorizationScope: { level: issuance.level },
		})
		.returning()
	if (!record) throw new Error("D1 returned no row for the issued token")
	return {
		token,
		listing: {
			id: record.id,
			description: record.description,
			level: record.authorizationScope.level,
			createdAt: record.createdAt,
			lastUsedAt: record.lastUsedAt,
		},
	}
}

export async function listApiTokens(database: ArchiveDatabase): Promise<Array<ApiTokenListing>> {
	const records = await database
		.select({
			id: apiTokens.id,
			description: apiTokens.description,
			authorizationScope: apiTokens.authorizationScope,
			createdAt: apiTokens.createdAt,
			lastUsedAt: apiTokens.lastUsedAt,
		})
		.from(apiTokens)
		.orderBy(desc(apiTokens.createdAt))
	return records.map(({ authorizationScope, ...record }) => ({ ...record, level: authorizationScope.level }))
}

export async function revokeApiToken(database: ArchiveDatabase, tokenId: string): Promise<void> {
	await database.delete(apiTokens).where(eq(apiTokens.id, tokenId))
}

/**
 * Resolves an `Authorization: Bearer <token>` header to the token's caller, or undefined for a
 * missing, malformed, unknown, or revoked token. The lookup compares SHA-256 digests through the
 * unique index: a guessed token's digest is unrelated to any stored digest, so the time the
 * comparison takes reveals nothing about a stored token.
 */
export async function authenticateApiToken(
	database: ArchiveDatabase,
	authorization: string | null,
	now: Date = new Date(),
): Promise<Extract<Caller, { kind: "api_token" }> | undefined> {
	const token = bearerPattern.exec(authorization ?? "")?.[1]
	if (token === undefined || !tokenPattern.test(token)) return undefined
	const [record] = await database
		.select({ id: apiTokens.id, authorizationScope: apiTokens.authorizationScope, lastUsedAt: apiTokens.lastUsedAt })
		.from(apiTokens)
		.where(eq(apiTokens.tokenSha256, await digestToken(token)))
	if (!record) return undefined
	if (
		record.lastUsedAt === null ||
		now.getTime() - record.lastUsedAt.getTime() >= LAST_USE_RECORDING_INTERVAL_MILLISECONDS
	) {
		await database.update(apiTokens).set({ lastUsedAt: now }).where(eq(apiTokens.id, record.id))
	}
	return { kind: "api_token", tokenId: record.id, scope: record.authorizationScope }
}
