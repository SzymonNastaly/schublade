import { applyD1Migrations, createExecutionContext, env, reset } from "cloudflare:test"
import { eq } from "drizzle-orm"
import { beforeAll, expect, inject, test } from "vitest"
import authorizationFixture from "../../test_fixtures/client_protocol/authorization.json"
import changesPageFixture from "../../test_fixtures/client_protocol/changes_page.json"
import { deleteDocument } from "../archive/document_revision"
import { deleteTaxonomyRecord } from "../archive/taxonomy_maintenance"
import { issueApiToken } from "../authentication/api_tokens"
import { connectDatabase } from "../database/client"
import {
	apiTokens,
	categories,
	changeJournalIdentity,
	documentTags,
	documents,
	extractedFields,
	householdMembers,
	senders,
	tags,
} from "../database/schema"
import { contentObjectKey, thumbnailObjectKey } from "../ingestion/source_file"
import { createRequestDispatcher } from "../request_dispatch"
import { createInMemorySearchIndex } from "../search/in_memory_search_index"
import type { AuthorizationScope } from "../authorization/caller_authorization"

// The identifiers, names, and times of test_fixtures/client_protocol/, which the native client parses too.
const JOURNAL_IDENTIFIER = "fc26a0aaf01faa9625397c1e4322b36c"
const mira = "50617283-94a5-4fb6-90c7-18293a4b5c6d"
const stadtwerke = "3e4f5061-7283-4d94-bea5-f60718293a4b"
const formerSender = "2d3e4f50-6172-4839-a4b5-c6d7e8f90a1b"
const invoice = "0b1c2d3e-4f50-4a61-8b72-c3d4e5f60718"
const electricity = "4f506172-8394-4ea5-8fb6-0718293a4b5c"
const taxYear = "6a7b8c9d-0e1f-4a2b-8c3d-4e5f60718293"
const statement = "4d1f0c9e-2a6b-4c3e-9a51-0b7f6e2d8c11"
const statementSha256 = "a3f1c2d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
const note = "7c8d9e0f-1a2b-4c3d-9e4f-5a6b7c8d9e0f"
const deletedDocument = "61728394-a5b6-4c7d-8e9f-0a1b2c3d4e5f"
const UNKNOWN_DOCUMENT_ID = "00000000-0000-4000-8000-000000000000"

const context = createExecutionContext()
const dispatchWithAccess = createRequestDispatcher(() => new Response("archive application"), false)
const environment = {
	...env,
	ACCESS_TEAM_DOMAIN: "archive-test.cloudflareaccess.com",
	ACCESS_AUD: "4714c1358e65fe4b408ad6d432a5f878f08194bdb4752441fd56faefa9b2b6f2",
}
const database = connectDatabase(env.DATABASE)
const tokens = { unrestricted: "", invoicesOnly: "", readOnly: "" }

/** Issues a token and gives it the scope, as no member can yet in Settings. */
async function issueScopedToken(description: string, authorizationScope: AuthorizationScope) {
	const { token, listing } = await issueApiToken(database, { description, level: "ingest" })
	await database.update(apiTokens).set({ authorizationScope }).where(eq(apiTokens.id, listing.id))
	return token
}

/**
 * One archive for every test of the file: none of them writes a record the journal follows. The
 * journal had issued 27 numbers when the client read its last page, so the page that follows
 * holds the entries 28 to 38.
 */
beforeAll(async () => {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	await database.update(changeJournalIdentity).set({ journalIdentifier: JOURNAL_IDENTIFIER })
	await database.insert(householdMembers).values({ id: mira, displayName: "Mira Wiśniewska", addresseeNames: [] })
	await database.insert(senders).values([
		{ id: stadtwerke, name: "Stadtwerke Talbrück GmbH", normalizedName: "stadtwerke talbruck gmbh" },
		{ id: formerSender, name: "Kabelnetz Talbrück", normalizedName: "kabelnetz talbruck" },
	])
	await database.insert(categories).values({
		id: invoice,
		name: "Invoice",
		normalizedName: "invoice",
		expectedFields: ["amount", "currency", "due_date", "iban", "invoice_number"],
	})
	await database.insert(tags).values([
		{ id: electricity, name: "strom", normalizedName: "strom" },
		{ id: taxYear, name: "steuer 2026", normalizedName: "steuer 2026", colorHex: "#2f6fde" },
	])
	await database.insert(documents).values({
		id: deletedDocument,
		storageObjectKey: `documents/${deletedDocument}/original.pdf`,
		mimeType: "application/pdf",
		byteSize: 1024,
		status: "archived",
	})
	await env.DATABASE.prepare("UPDATE sqlite_sequence SET seq = 27 WHERE name = 'change_journal'").run()

	await database.insert(documents).values([
		{
			id: statement,
			title: "Stadtwerke Talbrück Electricity Annual Statement 2025-2026",
			documentDate: "2026-09-22",
			senderId: stadtwerke,
			categoryId: invoice,
			summary: "Annual electricity statement with an additional payment of 72.09 euros.",
			storageObjectKey: `documents/${statement}/original.pdf`,
			mimeType: "application/pdf",
			byteSize: 184233,
			originalSha256: statementSha256,
			pageCount: 1,
			status: "archived",
			createdAt: new Date("2026-09-23T08:14:02Z"),
		},
	])
	await database.insert(documentTags).values([
		{ documentId: statement, tagId: electricity },
		{ documentId: statement, tagId: taxYear },
	])
	await database.insert(extractedFields).values([
		{ documentId: statement, fieldKey: "amount", fieldType: "number", valueNumber: 72.09, confidenceScore: 0.94 },
		{ documentId: statement, fieldKey: "currency", fieldType: "text", valueText: "EUR", confidenceScore: 0.99 },
		{ documentId: statement, fieldKey: "due_date", fieldType: "date", valueText: "2026-10-06" },
	])
	await database.insert(documents).values({
		id: note,
		title: "Handwritten Note on the Bicycle Repair",
		personMemberId: mira,
		summary: "A handwritten note that lists the parts replaced on a bicycle.",
		storageObjectKey: `documents/${note}/original.jpg`,
		mimeType: "image/jpeg",
		byteSize: 2381954,
		originalSha256: "5b6c7d8e9fa0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6",
		pageCount: 1,
		status: "archived",
		createdAt: new Date("2026-10-02T17:41:30Z"),
	})
	await database.insert(documents).values({
		id: "8d9e0f1a-2b3c-4d4e-8f5a-6b7c8d9e0f1a",
		storageObjectKey: "documents/8d9e0f1a-2b3c-4d4e-8f5a-6b7c8d9e0f1a/original.pdf",
		mimeType: "application/pdf",
		byteSize: 912004,
		originalSha256: "c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8",
		pageCount: 3,
		status: "recognizing_text",
		createdAt: new Date("2026-10-04T06:03:11Z"),
	})
	await database.insert(documents).values({
		id: "9e0f1a2b-3c4d-4e5f-9a6b-7c8d9e0f1a2b",
		storageObjectKey: "documents/9e0f1a2b-3c4d-4e5f-9a6b-7c8d9e0f1a2b/original.png",
		mimeType: "image/png",
		byteSize: 48213,
		status: "failed",
		failureReason: "unreadable_page",
		createdAt: new Date("2026-08-30T21:19:47Z"),
	})
	await deleteTaxonomyRecord(database, { kind: "sender", recordId: formerSender })
	await deleteDocument(
		{ database, storage: env.DOCUMENT_STORAGE, searchIndex: createInMemorySearchIndex().searchIndex },
		deletedDocument,
	)

	await env.DOCUMENT_STORAGE.put(`documents/${statement}/original.pdf`, "%PDF-1.7 statement", {
		httpMetadata: { contentType: "application/pdf" },
	})
	await env.DOCUMENT_STORAGE.put(contentObjectKey(statement), "# Annual statement", {
		httpMetadata: { contentType: "text/markdown; charset=utf-8" },
	})
	await env.DOCUMENT_STORAGE.put(thumbnailObjectKey(statement), "thumbnail", {
		httpMetadata: { contentType: "image/png" },
	})
	await env.DOCUMENT_STORAGE.put(`documents/${note}/original.jpg`, "note", {
		httpMetadata: { contentType: "image/jpeg" },
	})
	await env.DOCUMENT_STORAGE.put(contentObjectKey(note), "# Note", {
		httpMetadata: { contentType: "text/markdown; charset=utf-8" },
	})
	tokens.unrestricted = (await issueApiToken(database, { description: "MacBook of Jonas", level: "ingest" })).token
	tokens.invoicesOnly = await issueScopedToken("Tax adviser", { level: "read", allowedCategories: [invoice] })
	tokens.readOnly = await issueScopedToken("Reader", { level: "read" })
})

function send(path: string, init: { token?: string; method?: string; headers?: Record<string, string> } = {}) {
	const authorization: Record<string, string> =
		init.token === undefined ? {} : { Authorization: `Bearer ${init.token}` }
	return dispatchWithAccess(
		new Request(`https://archive.test${path}`, {
			method: init.method ?? "GET",
			headers: { ...authorization, ...init.headers },
		}),
		environment,
		context,
	)
}

async function answer(response: Response) {
	const body = new TextDecoder().decode(await response.arrayBuffer())
	return { status: response.status, contentType: response.headers.get("Content-Type"), body }
}

/** The protocol promises no order of the entries, so a page is compared as a map keyed by record. */
function keyedByRecord({ changes, ...page }: { changes: Array<{ record: string; id: string }> }) {
	return { ...page, changes: Object.fromEntries(changes.map((change) => [`${change.record} ${change.id}`, change])) }
}

test("the authorization and a page of changes equal the wire fixtures that the native client parses", async () => {
	const authorization = await send("/api/v1/authorization", { token: tokens.unrestricted })
	const changes = await send(`/api/v1/changes?after=${JOURNAL_IDENTIFIER}.27`, { token: tokens.unrestricted })

	expect({
		authorization: await authorization.json(),
		changes: keyedByRecord(await changes.json<Parameters<typeof keyedByRecord>[0]>()),
		cacheControl: [authorization.headers.get("Cache-Control"), changes.headers.get("Cache-Control")],
	}).toEqual({
		authorization: authorizationFixture,
		changes: keyedByRecord(changesPageFixture),
		cacheControl: ["no-store", "no-store"],
	})
})

const newRoutes = [
	"/api/v1/authorization",
	"/api/v1/changes",
	`/api/v1/documents/${note}/original`,
	`/api/v1/documents/${note}/text`,
	`/api/v1/documents/${note}/thumbnail`,
]

test("each new route refuses a missing token and another method, a read token reads but cannot ingest, and a document outside the scope is not found", async () => {
	const missingToken = await Promise.all(newRoutes.map((path) => send(path)))
	const otherMethod = await Promise.all(
		newRoutes.map((path) => send(path, { token: tokens.unrestricted, method: "POST" })),
	)
	const readToken = await Promise.all(newRoutes.map((path) => send(path, { token: tokens.readOnly })))
	const readTokenIngesting = await send("/api/v1/contents/lookup", { token: tokens.readOnly, method: "POST" })
	const outsideScope = await Promise.all(newRoutes.slice(2).map((path) => send(path, { token: tokens.invoicesOnly })))
	const insideScope = await send(`/api/v1/documents/${statement}/text`, { token: tokens.invoicesOnly })

	expect({
		missingToken: await Promise.all(missingToken.map(answer)),
		challenges: missingToken.map((response) => response.headers.get("WWW-Authenticate")),
		otherMethod: await Promise.all(otherMethod.map(answer)),
		allow: otherMethod.map((response) => response.headers.get("Allow")),
		readToken: readToken.map((response) => response.status),
		readTokenIngesting: await answer(readTokenIngesting),
		outsideScope: await Promise.all(outsideScope.map(answer)),
		insideScope: await answer(insideScope),
	}).toEqual({
		missingToken: newRoutes.map(() => ({
			status: 401,
			contentType: "application/problem+json",
			body: '{"type":"about:blank","title":"Unauthorized","status":401,"detail":"Send a valid API token in the Authorization header"}',
		})),
		challenges: newRoutes.map(() => "Bearer"),
		otherMethod: newRoutes.map(() => ({
			status: 405,
			contentType: "application/problem+json",
			body: '{"type":"about:blank","title":"Method Not Allowed","status":405,"detail":"Send this request with GET"}',
		})),
		allow: newRoutes.map(() => "GET"),
		readToken: [200, 200, 200, 200, 200],
		readTokenIngesting: {
			status: 403,
			contentType: "application/problem+json",
			body: '{"type":"about:blank","title":"Forbidden","status":403,"detail":"The API token does not permit ingesting documents"}',
		},
		outsideScope: newRoutes.slice(2).map(() => ({
			status: 404,
			contentType: "application/problem+json",
			body: `{"type":"about:blank","title":"Not Found","status":404,"detail":"No document has the identifier ${note}"}`,
		})),
		insideScope: { status: 200, contentType: "text/markdown; charset=utf-8", body: "# Annual statement" },
	})
})

test("an original carries its SHA-256 as its entity tag and answers 304 to it, and the text answers 304 to R2's", async () => {
	const original = await send(`/api/v1/documents/${statement}/original`, { token: tokens.unrestricted })
	const revalidated = await send(`/api/v1/documents/${statement}/original`, {
		token: tokens.unrestricted,
		headers: { "If-None-Match": `"${statementSha256}"` },
	})
	const text = await send(`/api/v1/documents/${statement}/text`, { token: tokens.unrestricted })
	const textTag = text.headers.get("ETag") ?? ""
	const textRevalidated = await send(`/api/v1/documents/${statement}/text`, {
		token: tokens.unrestricted,
		headers: { "If-None-Match": textTag },
	})
	const unknown = await send(`/api/v1/documents/${UNKNOWN_DOCUMENT_ID}/original`, { token: tokens.unrestricted })

	expect({
		original: { ...(await answer(original)), headers: Object.fromEntries(original.headers) },
		revalidated: { ...(await answer(revalidated)), etag: revalidated.headers.get("ETag") },
		textTagIsR2s: textTag.startsWith('"') && textTag !== `"${statementSha256}"`,
		textRevalidated: { ...(await answer(textRevalidated)), etag: textRevalidated.headers.get("ETag") },
		unknown: (await answer(unknown)).status,
	}).toEqual({
		original: {
			status: 200,
			contentType: "application/pdf",
			body: "%PDF-1.7 statement",
			headers: {
				"cache-control": "private, no-store",
				"content-disposition": "inline",
				"content-length": "18",
				"content-security-policy": "sandbox",
				"content-type": "application/pdf",
				etag: `"${statementSha256}"`,
				"x-content-type-options": "nosniff",
			},
		},
		revalidated: { status: 304, contentType: null, body: "", etag: `"${statementSha256}"` },
		textTagIsR2s: true,
		textRevalidated: { status: 304, contentType: null, body: "", etag: textTag },
		unknown: 404,
	})
})

test("a cursor that does not parse and an undefined parameter answer 400, and a cursor of another journal or beyond the end answers 410", async () => {
	const changes = (query: string) => send(`/api/v1/changes?${query}`, { token: tokens.unrestricted })
	const problemOf = async (response: Response) => {
		const { status, detail } = await response.json<{ status: number; detail: string }>()
		return { status, detail }
	}

	expect({
		unparsable: await problemOf(await changes(`after=${JOURNAL_IDENTIFIER}.027`)),
		repeated: await problemOf(await changes(`after=${JOURNAL_IDENTIFIER}.27&after=${JOURNAL_IDENTIFIER}.28`)),
		undefinedParameter: await problemOf(await changes(`after=${JOURNAL_IDENTIFIER}.27&limit=10`)),
		anotherJournal: await problemOf(await changes("after=0123456789abcdef0123456789abcdef.27")),
		beyondTheEnd: await problemOf(await changes(`after=${JOURNAL_IDENTIFIER}.39`)),
	}).toEqual({
		unparsable: {
			status: 400,
			detail: "The cursor is not one this archive answered. Send the cursor of the last page as it came.",
		},
		repeated: {
			status: 400,
			detail: "The cursor is not one this archive answered. Send the cursor of the last page as it came.",
		},
		undefinedParameter: { status: 400, detail: "The journal takes only the parameter after, not limit" },
		anotherJournal: { status: 410, detail: "This archive holds no such position. Read the journal from the start." },
		beyondTheEnd: { status: 410, detail: "This archive holds no such position. Read the journal from the start." },
	})
})
