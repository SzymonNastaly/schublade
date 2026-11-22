import { eq } from "drizzle-orm"
import { deniedTagsAllExist } from "../archive/document_listing"
import { isRestrictedScope } from "../authorization/caller_authorization"
import { apiTokens } from "../database/schema"
import { sha256Hexadecimal } from "../ingestion/content_identity"
import { formatJournalCursor, parseJournalCursor, readJournalIdentity, readJournalPage } from "./change_journal"
import { problem, undefinedParameters } from "./problem_details"
import type { AuthorizationScope, Caller } from "../authorization/caller_authorization"
import type { ArchiveDatabase } from "../database/client"
import type { JournaledRecord, RecordChange } from "./change_journal"

// This module owns the wire names of GET /api/v1/authorization and GET /api/v1/changes, which
// notes/client_protocol.md defines and test_fixtures/client_protocol/ holds for both implementations.

type ApiTokenCaller = Extract<Caller, { kind: "api_token" }>

const NO_STORE = { "Cache-Control": "no-store" }

/**
 * Equal digests mean equal visibility, so the lists are deduplicated and sorted, an absent list is
 * null, and the level takes no part. A list added to the schema fails to compile here until the
 * digest reads it, so no change of what a token sees can leave the digest unchanged.
 */
function scopeDigest(scope: AuthorizationScope): Promise<string> {
	const lists = {
		allowedCategories: scope.allowedCategories,
		allowedTags: scope.allowedTags,
		deniedTags: scope.deniedTags,
		allowedSenders: scope.allowedSenders,
	} satisfies Record<Exclude<keyof AuthorizationScope, "level">, Array<string> | undefined>
	const canonical = Object.values(lists).map((list) => (list === undefined ? null : [...new Set(list)].sort()))
	return sha256Hexadecimal(new TextEncoder().encode(JSON.stringify(canonical)))
}

export async function serveAuthorization(
	database: ArchiveDatabase,
	request: Request,
	caller: ApiTokenCaller,
): Promise<Response> {
	const names = undefinedParameters(request, [])
	if (names !== undefined) return problem(400, `This request takes no parameters, not ${names}`)
	const [[token], journalIdentifier] = await Promise.all([
		database.select({ description: apiTokens.description }).from(apiTokens).where(eq(apiTokens.id, caller.tokenId)),
		readJournalIdentity(database),
	])
	if (!token) throw new Error(`The API token ${caller.tokenId} was revoked while its request ran`)
	return Response.json(
		{
			journal_identifier: journalIdentifier,
			token: {
				description: token.description,
				permission_level: caller.scope.level,
				restricted: isRestrictedScope(caller.scope),
				scope_digest: await scopeDigest(caller.scope),
			},
		},
		{ headers: NO_STORE },
	)
}

/** A creation time holds whole seconds, so its milliseconds are always zero. */
const wireTime = (time: Date) => time.toISOString().replace(/\.000Z$/, "Z")

function wireRecord(record: JournaledRecord) {
	switch (record.kind) {
		case "document":
			return {
				document: {
					status: record.status,
					failure_reason: record.failureReason,
					title: record.title,
					document_date: record.documentDate,
					sender_id: record.senderId,
					category_id: record.categoryId,
					person:
						record.person.kind === "member" ? { kind: "member", member_id: record.person.memberId } : record.person,
					summary: record.summary,
					media_type: record.mimeType,
					byte_size: record.byteSize,
					page_count: record.pageCount,
					original_sha256: record.originalSha256,
					arrived_at: wireTime(record.createdAt),
					tag_ids: record.tagIds,
					fields: record.fields.map((field) => ({
						key: field.fieldKey,
						type: field.fieldType,
						value: field.value,
						confidence: field.confidenceScore,
					})),
				},
			}
		case "household_member":
			return { household_member: { display_name: record.displayName } }
		case "sender":
			return { sender: { name: record.name } }
		case "category":
			return { category: { name: record.name, expected_fields: record.expectedFields } }
		case "tag":
			return { tag: { name: record.name, color_hex: record.colorHex } }
	}
}

function wireChange(change: RecordChange) {
	if (change.change === "removal") return { record: change.kind, id: change.id, change: "removal" }
	return { record: change.record.kind, id: change.record.id, change: "upsert", ...wireRecord(change.record) }
}

export async function serveChanges(
	database: ArchiveDatabase,
	request: Request,
	caller: ApiTokenCaller,
): Promise<Response> {
	const names = undefinedParameters(request, ["after"])
	if (names !== undefined) return problem(400, `The journal takes only the parameter after, not ${names}`)
	const [after, ...repeated] = new URL(request.url).searchParams.getAll("after")
	const cursor = after === undefined ? undefined : parseJournalCursor(after)
	if (after !== undefined && (cursor === undefined || repeated.length > 0)) {
		return problem(400, "The cursor is not one this archive answered. Send the cursor of the last page as it came.")
	}
	if (!(await deniedTagsAllExist(database, caller.scope.deniedTags))) {
		return problem(403, "A tag this token excludes no longer exists. Issue a new token.")
	}
	const outcome = await readJournalPage(database, caller.scope, cursor)
	if (outcome.kind === "cursor_refused") {
		return problem(410, "This archive holds no such position. Read the journal from the start.")
	}
	const { changes, nextCursor, remainingEntries } = outcome.page
	return Response.json(
		{
			changes: changes.map(wireChange),
			cursor: formatJournalCursor(nextCursor),
			complete: remainingEntries === 0,
			remaining: remainingEntries,
		},
		{ headers: NO_STORE },
	)
}
