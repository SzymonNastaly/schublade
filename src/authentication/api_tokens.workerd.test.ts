import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { apiTokens } from "../database/schema"
import { authenticateApiToken, issueApiToken, listApiTokens, revokeApiToken } from "./api_tokens"

async function sha256Hexadecimal(text: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
	return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
}

test("an issued token authenticates until it is revoked and records its use at most once an hour", async () => {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)

	const { token, listing } = await issueApiToken(database, {
		description: "QuickScan on Jonas's phone",
		level: "ingest",
	})
	const storedRows = await database.select().from(apiTokens)
	const firstCaller = await authenticateApiToken(database, `Bearer ${token}`, new Date("2026-11-06T10:00:00Z"))
	await authenticateApiToken(database, `Bearer ${token}`, new Date("2026-11-06T10:59:00Z"))
	const [afterUseWithinHour] = await listApiTokens(database)
	await authenticateApiToken(database, `bearer ${token}`, new Date("2026-11-06T11:00:00Z"))
	const [afterUseAnHourLater] = await listApiTokens(database)
	await revokeApiToken(database, listing.id)

	expect({
		token,
		storedColumns: storedRows.map(({ description, tokenSha256, authorizationScope }) => ({
			description,
			tokenSha256,
			authorizationScope,
		})),
		firstCaller,
		lastUseAfterUseWithinHour: afterUseWithinHour?.lastUsedAt,
		lastUseAfterUseAnHourLater: afterUseAnHourLater?.lastUsedAt,
		callerAfterRevocation: await authenticateApiToken(database, `Bearer ${token}`),
		listingsAfterRevocation: await listApiTokens(database),
	}).toEqual({
		token: expect.stringMatching(/^schublade_[A-Za-z0-9_-]{43}$/),
		storedColumns: [
			{
				description: "QuickScan on Jonas's phone",
				tokenSha256: await sha256Hexadecimal(token),
				authorizationScope: { level: "ingest" },
			},
		],
		firstCaller: { kind: "api_token", tokenId: listing.id, scope: { level: "ingest" } },
		lastUseAfterUseWithinHour: new Date("2026-11-06T10:00:00Z"),
		lastUseAfterUseAnHourLater: new Date("2026-11-06T11:00:00Z"),
		callerAfterRevocation: undefined,
		listingsAfterRevocation: [],
	})
})
