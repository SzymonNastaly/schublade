import { and, desc, eq, gt, isNull } from "drizzle-orm"
import { queryArchiveFacets } from "../archive/document_listing"
import { authorizationGrants } from "../database/schema"
import { describeAuthorizationScope } from "./grant_selection"
import type { AuthorizationScope } from "../authorization/caller_authorization"
import type { ArchiveDatabase } from "../database/client"

/** How long a client stays connected, which the OAuth provider applies to its refresh tokens. */
export const AUTHORIZATION_GRANT_LIFETIME_SECONDS = 30 * 24 * 60 * 60

export interface AuthorizedClientListing {
	grantId: string
	clientName: string
	accessSummary: string
	authorizedAt: Date
	expiresAt: Date
}

/** A client that authorizes again replaces its earlier grant, as the OAuth provider does in OAUTH_KV. */
export async function recordAuthorizationGrant(
	database: ArchiveDatabase,
	grant: { id: string; clientId: string; clientName: string; authorizationScope: AuthorizationScope },
): Promise<void> {
	await database.batch([
		database
			.update(authorizationGrants)
			.set({ revokedAt: new Date() })
			.where(and(eq(authorizationGrants.clientId, grant.clientId), isNull(authorizationGrants.revokedAt))),
		database.insert(authorizationGrants).values(grant),
	])
}

/**
 * The scope of a grant that still stands. D1 decides this, not OAUTH_KV: KV is eventually
 * consistent and has no compare-and-set, so a refresh served by a location that still caches a
 * deleted grant would write it back.
 */
export async function readGrantedScope(
	database: ArchiveDatabase,
	grantId: string,
): Promise<AuthorizationScope | undefined> {
	const [grant] = await database
		.select({ authorizationScope: authorizationGrants.authorizationScope })
		.from(authorizationGrants)
		.where(and(eq(authorizationGrants.id, grantId), isNull(authorizationGrants.revokedAt)))
	return grant?.authorizationScope
}

export async function listAuthorizedClients(
	database: ArchiveDatabase,
	now: Date = new Date(),
): Promise<Array<AuthorizedClientListing>> {
	const lifetimeMilliseconds = AUTHORIZATION_GRANT_LIFETIME_SECONDS * 1000
	const [grants, facets] = await Promise.all([
		database
			.select()
			.from(authorizationGrants)
			.where(
				and(
					isNull(authorizationGrants.revokedAt),
					gt(authorizationGrants.createdAt, new Date(now.getTime() - lifetimeMilliseconds)),
				),
			)
			.orderBy(desc(authorizationGrants.createdAt)),
		queryArchiveFacets(database),
	])
	return grants.map((grant) => ({
		grantId: grant.id,
		clientName: grant.clientName,
		accessSummary: describeAuthorizationScope(grant.authorizationScope, facets),
		authorizedAt: grant.createdAt,
		expiresAt: new Date(grant.createdAt.getTime() + lifetimeMilliseconds),
	}))
}

export async function revokeAuthorizedClient(database: ArchiveDatabase, grantId: string): Promise<void> {
	await database
		.update(authorizationGrants)
		.set({ revokedAt: new Date() })
		.where(and(eq(authorizationGrants.id, grantId), isNull(authorizationGrants.revokedAt)))
}
