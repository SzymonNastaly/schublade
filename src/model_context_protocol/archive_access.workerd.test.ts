import { applyD1Migrations, createExecutionContext, env, reset } from "cloudflare:test"
import { eq } from "drizzle-orm"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { categories, documentTags, documents, tags } from "../database/schema"
import { contentObjectKey } from "../ingestion/source_file"
import { createRequestDispatcher } from "../request_dispatch"
import { listAuthorizedClients, recordAuthorizationGrant, revokeAuthorizedClient } from "./authorization_grants"
import type { SearchIndex } from "../search/document_indexing"

const origin = "https://archive.test"
const redirectUri = "https://client.example/callback"
const codeVerifier = "verifier-of-the-test-client-that-is-long-enough-for-pkce-0123456789"

const invoiceCategory = "b2000000-0000-4000-8000-000000000001"
const medicalCategory = "b2000000-0000-4000-8000-000000000002"
const privateTag = "d2000000-0000-4000-8000-000000000001"
const invoice = "e2000000-0000-4000-8000-000000000001"
const medicalLetter = "e2000000-0000-4000-8000-000000000002"

// The exemption stands in for a signed-in household member on the consent page.
const dispatch = createRequestDispatcher(() => new Response("archive application"), true)

const searchRequests: Array<Parameters<SearchIndex["search"]>[0]> = []

// Answers like an index that ignores the filter, so only D1 keeps the other category out.
const searchIndex: SearchIndex = {
	search: (request) => {
		searchRequests.push(request)
		return Promise.resolve({
			search_query: request.query ?? "",
			chunks: [invoice, medicalLetter].map((id) => ({
				id,
				type: "text",
				score: 0.9,
				text: `Passage of ${id}`,
				item: { key: `${id}.md` },
			})),
		})
	},
	items: {
		upload: () => Promise.reject(new Error("Reading does not upload")),
		list: () => Promise.resolve({ result: [] }),
		delete: () => Promise.reject(new Error("Reading does not delete")),
	},
}

const environment = { ...env, SEARCH_INDEX: searchIndex as unknown as typeof env.SEARCH_INDEX }

const send = (path: string, init?: RequestInit) =>
	dispatch(new Request(`${origin}${path}`, init), environment, createExecutionContext())

async function prepareArchive() {
	await reset()
	searchRequests.length = 0
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	await database.insert(categories).values([
		{ id: invoiceCategory, name: "Invoice", normalizedName: "invoice", expectedFields: [] },
		{ id: medicalCategory, name: "Medical", normalizedName: "medical", expectedFields: [] },
	])
	await database.insert(tags).values({ id: privateTag, name: "private", normalizedName: "private" })
	const documentOf = (id: string, categoryId: string, title: string) => ({
		id,
		title,
		categoryId,
		storageObjectKey: `documents/${id}/original.pdf`,
		mimeType: "application/pdf",
		byteSize: 1024,
		status: "archived" as const,
	})
	await database
		.insert(documents)
		.values([
			documentOf(invoice, invoiceCategory, "Werkhof invoice"),
			documentOf(medicalLetter, medicalCategory, "Dental letter"),
		])
	await env.DOCUMENT_STORAGE.put(contentObjectKey(invoice), "# Werkhof invoice text")
	await env.DOCUMENT_STORAGE.put(contentObjectKey(medicalLetter), "# Dental letter text")
	return database
}

function base64Url(bytes: ArrayBuffer): string {
	return btoa(String.fromCharCode(...new Uint8Array(bytes)))
		.replaceAll("+", "-")
		.replaceAll("/", "_")
		.replace(/=+$/, "")
}

/** Registers a client, approves its consent page with the given form values, and redeems the code. */
async function authorizeClient(consentValues: Array<[string, string]>) {
	const registration = await send("/oauth/register", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({
			client_name: "Claude",
			redirect_uris: [redirectUri],
			token_endpoint_auth_method: "none",
			grant_types: ["authorization_code", "refresh_token"],
			response_types: ["code"],
		}),
	})
	const { client_id: clientId } = await registration.json<{ client_id: string }>()
	const codeChallenge = base64Url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(codeVerifier)))
	const authorizationPath = `/authorize?${new URLSearchParams({
		response_type: "code",
		client_id: clientId,
		redirect_uri: redirectUri,
		code_challenge: codeChallenge,
		code_challenge_method: "S256",
		state: "client-state",
		resource: `${origin}/mcp`,
	})}`
	const consentPage = await send(authorizationPath)
	const pageText = await consentPage.text()
	const handle = /name="handle" value="([^"]+)"/.exec(pageText)?.[1]
	const cookie = consentPage.headers.get("Set-Cookie")?.split(";")[0]
	if (handle === undefined || cookie === undefined) throw new Error(`The consent page failed: ${pageText}`)
	const approval = await send(authorizationPath, {
		method: "POST",
		redirect: "manual",
		headers: { "Content-Type": "application/x-www-form-urlencoded", Cookie: cookie, Origin: origin },
		body: new URLSearchParams([["handle", handle], ["decision", "approve"], ...consentValues]),
	})
	const code = new URL(approval.headers.get("Location") ?? "about:blank").searchParams.get("code")
	if (code === null) throw new Error(`The approval failed: ${approval.status} ${await approval.text()}`)
	const exchange = await send("/oauth/token", {
		method: "POST",
		headers: { "Content-Type": "application/x-www-form-urlencoded" },
		body: new URLSearchParams({
			grant_type: "authorization_code",
			code,
			redirect_uri: redirectUri,
			client_id: clientId,
			code_verifier: codeVerifier,
			resource: `${origin}/mcp`,
		}),
	})
	const { access_token: accessToken, refresh_token: refreshToken } = await exchange.json<{
		access_token: string
		refresh_token: string
	}>()
	return { accessToken, refreshToken, clientId }
}

function callMcp(accessToken: string, name: string, toolArguments: Record<string, unknown> = {}) {
	return send("/mcp", {
		method: "POST",
		headers: {
			Authorization: `Bearer ${accessToken}`,
			"Content-Type": "application/json",
			Accept: "application/json, text/event-stream",
			"MCP-Protocol-Version": "2025-06-18",
		},
		body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: toolArguments } }),
	})
}

interface ToolResult {
	isError?: boolean
	content: Array<{ text: string }>
}

async function toolResult(accessToken: string, name: string, toolArguments?: Record<string, unknown>) {
	const response = await callMcp(accessToken, name, toolArguments)
	const body = await response.text()
	const message = /^data: (.+)$/m.exec(body)?.[1] ?? body
	const { result } = JSON.parse(message) as { result: ToolResult }
	return { isError: result.isError ?? false, text: result.content[0]?.text ?? "" }
}

const parsedText = async <TValue>(accessToken: string, name: string, toolArguments?: Record<string, unknown>) =>
	JSON.parse((await toolResult(accessToken, name, toolArguments)).text) as TValue

const invoiceOnly: Array<[string, string]> = [
	["access", "selected"],
	["allowedCategories", invoiceCategory],
]

test("a client granted one category reads nothing else through search, listing, filter options, or reading", async () => {
	await prepareArchive()

	const { accessToken } = await authorizeClient(invoiceOnly)
	const found = await parsedText<Array<{ id: string; matchingPassage: string }>>(accessToken, "search_documents", {
		query: "letter",
	})
	const listed = await parsedText<{ totalDocuments: number; documents: Array<{ id: string; link: string }> }>(
		accessToken,
		"list_documents",
	)
	const options = await parsedText<{ categories: Array<{ name: string }> }>(accessToken, "list_filter_options")
	const reading = await parsedText<{ markdown: string }>(accessToken, "read_document", { documentId: invoice })
	const refusedReading = await toolResult(accessToken, "read_document", { documentId: medicalLetter })

	expect({
		found,
		indexFilter: searchRequests[0]?.ai_search_options?.retrieval?.filters,
		listed,
		categories: options.categories.map((category) => category.name),
		markdown: reading.markdown,
		refusedReading,
	}).toEqual({
		found: [expect.objectContaining({ id: invoice, matchingPassage: `Passage of ${invoice}` })],
		indexFilter: { category: { $in: [invoiceCategory] } },
		listed: {
			totalDocuments: 1,
			documents: [expect.objectContaining({ id: invoice, link: `${origin}/documents/${invoice}` })],
		},
		categories: ["Invoice"],
		markdown: "# Werkhof invoice text",
		refusedReading: { isError: true, text: `There is no document ${medicalLetter}` },
	})
})

test("a request without a token gets a challenge that leads to the authorization server", async () => {
	await prepareArchive()

	const challenge = await send("/mcp", { method: "POST" })
	const resource = await send("/.well-known/oauth-protected-resource/mcp")
	const server = await send("/.well-known/oauth-authorization-server")

	expect({
		status: challenge.status,
		header: challenge.headers.get("WWW-Authenticate"),
		resource: await resource.json(),
		server: await server.json(),
	}).toEqual({
		status: 401,
		header: expect.stringContaining(`resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp"`),
		resource: expect.objectContaining({ resource: `${origin}/mcp`, authorization_servers: [origin] }),
		server: expect.objectContaining({
			issuer: origin,
			authorization_endpoint: `${origin}/authorize`,
			token_endpoint: `${origin}/oauth/token`,
			registration_endpoint: `${origin}/oauth/register`,
		}),
	})
})

test("Settings lists a connected client with what it may read, and disconnecting it survives a refresh", async () => {
	const database = await prepareArchive()
	const { accessToken, refreshToken, clientId } = await authorizeClient(invoiceOnly)

	const clients = await listAuthorizedClients(database)
	await revokeAuthorizedClient(database, clients[0]?.grantId ?? "")
	const afterDisconnecting = await callMcp(accessToken, "list_documents")
	// Stands for a location whose KV still caches the grant, which lets the refresh succeed.
	const refreshed = await send("/oauth/token", {
		method: "POST",
		headers: { "Content-Type": "application/x-www-form-urlencoded" },
		body: new URLSearchParams({
			grant_type: "refresh_token",
			refresh_token: refreshToken,
			client_id: clientId,
			resource: `${origin}/mcp`,
		}),
	})
	const { access_token: refreshedToken } = await refreshed.json<{ access_token: string }>()
	const afterRefreshing = await callMcp(refreshedToken, "list_documents")

	expect({
		clients: clients.map(({ clientName, accessSummary }) => ({ clientName, accessSummary })),
		statusAfterDisconnecting: afterDisconnecting.status,
		challenge: afterDisconnecting.headers.get("WWW-Authenticate"),
		refreshStatus: refreshed.status,
		statusAfterRefreshing: afterRefreshing.status,
		clientsAfterwards: await listAuthorizedClients(database),
	}).toEqual({
		clients: [{ clientName: "Claude", accessSummary: "Categories: Invoice" }],
		statusAfterDisconnecting: 401,
		challenge: expect.stringContaining(`resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp"`),
		refreshStatus: 200,
		statusAfterRefreshing: 401,
		clientsAfterwards: [],
	})
})

test("a client that authorizes again replaces its earlier grant, and an expired grant leaves Settings", async () => {
	const database = await prepareArchive()
	const clientId = "client-that-authorizes-twice"
	const first = "a2000000-0000-4000-8000-000000000001"
	const second = "a2000000-0000-4000-8000-000000000002"

	await recordAuthorizationGrant(database, {
		id: first,
		clientId,
		clientName: "Claude",
		authorizationScope: { level: "read" },
	})
	await recordAuthorizationGrant(database, {
		id: second,
		clientId,
		clientName: "Claude",
		authorizationScope: { level: "read" },
	})

	const ids = async (now?: Date) => (await listAuthorizedClients(database, now)).map((client) => client.grantId)
	const thirtyOneDaysLater = new Date(Date.now() + 31 * 24 * 60 * 60 * 1000)
	expect({ now: await ids(), later: await ids(thirtyOneDaysLater) }).toEqual({ now: [second], later: [] })
})

test("registration refuses oversized client metadata before storing anything", async () => {
	await prepareArchive()

	const response = await send("/oauth/register", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({
			client_name: "x".repeat(9000),
			redirect_uris: [redirectUri],
			token_endpoint_auth_method: "none",
		}),
	})

	expect({ status: response.status, stored: (await env.OAUTH_KV.list()).keys }).toEqual({ status: 400, stored: [] })
})

test("a grant stops working when a tag it excludes no longer exists, and a document with that tag stays hidden until then", async () => {
	const database = await prepareArchive()
	await database.insert(documentTags).values({ documentId: medicalLetter, tagId: privateTag })
	const { accessToken } = await authorizeClient([
		["access", "selected"],
		["deniedTags", privateTag],
	])

	const before = await parsedText<{ documents: Array<{ id: string }> }>(accessToken, "list_documents")
	await database.delete(tags).where(eq(tags.id, privateTag))
	const after = await callMcp(accessToken, "list_documents")

	expect({
		before: before.documents.map((document) => document.id),
		status: after.status,
		body: await after.json(),
	}).toEqual({
		before: [invoice],
		status: 403,
		body: { error: "A tag this grant excludes no longer exists. Authorize the client again." },
	})
})
