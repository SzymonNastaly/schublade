import { applyD1Migrations, createExecutionContext, env, reset } from "cloudflare:test"
import { eq } from "drizzle-orm"
import { expect, inject, test } from "vitest"
import scannedInvoice from "../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { issueApiToken } from "./authentication/api_tokens"
import { connectDatabase } from "./database/client"
import { clientRouteDefinitions } from "./client_protocol/client_paths"
import { apiTokens } from "./database/schema"
import { createRequestDispatcher } from "./request_dispatch"

const context = createExecutionContext()
const dispatchWithAccess = createRequestDispatcher(() => new Response("archive application"), false)
const dispatch = (request: Request, environment: Parameters<typeof dispatchWithAccess>[1]) =>
	dispatchWithAccess(request, environment, context)

async function prepareArchive() {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	const workflow = { create: () => Promise.resolve() }
	const environment = {
		...env,
		ACCESS_TEAM_DOMAIN: "archive-test.cloudflareaccess.com",
		ACCESS_AUD: "4714c1358e65fe4b408ad6d432a5f878f08194bdb4752441fd56faefa9b2b6f2",
		DOCUMENT_INGESTION_WORKFLOW: workflow as unknown as Workflow,
	}
	const { token } = await issueApiToken(database, { description: "Network scanner", level: "ingest" })
	return { database, environment, token }
}

/** Issues a token whose scope admits no document, as no member can yet in Settings. */
async function issueRestrictedToken(database: ReturnType<typeof connectDatabase>) {
	const { token, listing } = await issueApiToken(database, { description: "Tax adviser", level: "read" })
	await database
		.update(apiTokens)
		.set({ authorizationScope: { level: "read", allowedCategories: [] } })
		.where(eq(apiTokens.id, listing.id))
	return token
}

function uploadRequest(path: string, headers: Record<string, string>): Request {
	const formData = new FormData()
	formData.append("files", new File([scannedInvoice], "scan.pdf"))
	return new Request(`https://archive.test${path}`, { method: "POST", headers, body: formData })
}

async function outcome(response: Response) {
	return { status: response.status, body: await response.text() }
}

test("every other path requires an Access assertion even with a valid token, and cross-site writes are refused first", async () => {
	const { environment, token } = await prepareArchive()
	const bearer = { Authorization: `Bearer ${token}` }
	const documentPath = "/api/v1/documents/4d1f0c9e-2a6b-4c3e-9a51-0b7f6e2d8c11"

	const responses = [
		await dispatch(uploadRequest("/api/documents", bearer), environment),
		await dispatch(uploadRequest("/api/documents/ingest", bearer), environment),
		await dispatch(uploadRequest("/api/v1/contents/lookup/", bearer), environment),
		await dispatch(uploadRequest(`/api/v1/contents/${"0".repeat(64)}`, bearer), environment),
		await dispatch(uploadRequest(`/api/v1/submitted_documents/${"A".repeat(64)}`, bearer), environment),
		await dispatch(uploadRequest("/api/v1/documents/not-an-identifier", bearer), environment),
		await dispatch(uploadRequest("/api/v1/x", bearer), environment),
		await dispatch(uploadRequest("/api/v1", bearer), environment),
		await dispatch(new Request("https://archive.test/api/v1/authorization/", { headers: bearer }), environment),
		await dispatch(new Request("https://archive.test/api/v1/Authorization", { headers: bearer }), environment),
		await dispatch(new Request("https://archive.test/api/v1/changes/", { headers: bearer }), environment),
		await dispatch(new Request("https://archive.test/api/v1/journal", { headers: bearer }), environment),
		await dispatch(
			new Request(`https://archive.test${documentPath.toUpperCase()}/original`, { headers: bearer }),
			environment,
		),
		await dispatch(new Request(`https://archive.test${documentPath}/original/`, { headers: bearer }), environment),
		await dispatch(new Request(`https://archive.test${documentPath}/originals`, { headers: bearer }), environment),
		await dispatch(new Request(`https://archive.test${documentPath}/text/page`, { headers: bearer }), environment),
		await dispatch(new Request(`https://archive.test${documentPath}/Thumbnail`, { headers: bearer }), environment),
		await dispatch(
			new Request(`https://archive.test/api/submitted_documents/${"0".repeat(64)}`, { method: "PUT", headers: bearer }),
			environment,
		),
		await dispatch(new Request("https://archive.test/settings", { headers: bearer }), environment),
		await dispatch(new Request("https://archive.test/authorize", { headers: bearer }), environment),
		await dispatch(uploadRequest("/mcp/", bearer), environment),
		await dispatch(uploadRequest("/mcp/tools", bearer), environment),
		await dispatch(uploadRequest("/oauth/token/refresh", bearer), environment),
		await dispatch(new Request("https://archive.test/.well-known/oauth-protected-resource"), environment),
		await dispatch(
			uploadRequest("/api/v1/contents/lookup", { ...bearer, Origin: "https://elsewhere.example" }),
			environment,
		),
	]

	expect(await Promise.all(responses.map(outcome))).toEqual([
		...Array.from({ length: 24 }, () => ({ status: 403, body: "Access denied: assertion_missing" })),
		{ status: 403, body: "Cross-site request refused: https://elsewhere.example" },
	])
})

const DOCUMENT_IDENTIFIER = "4d1f0c9e-2a6b-4c3e-9a51-0b7f6e2d8c11"
// The digest of test_fixtures/documents/electricity_invoice_scanned.pdf.
const SCANNED_INVOICE_SHA256 = "3551f8806c62a6b604bfbeab63ececeac46ee9df4e7db1ff5835377ff07ab0ed"

/** A path that the pattern of a client route matches, written from the pattern's own source. */
function matchingPath(pattern: RegExp): string {
	const path = pattern.source
		.replace(/^\^|\$$/g, "")
		.replaceAll("\\/", "/")
		.replace("([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", DOCUMENT_IDENTIFIER)
		.replace("([0-9a-f]{64})", SCANNED_INVOICE_SHA256)
		.replace("(original|text|thumbnail)", "original")
	if (!/^[a-z0-9/_-]+$/.test(path)) throw new Error(`Give matchingPath a value for each parameter of ${pattern.source}`)
	return path
}

// Every route of the table appears here with what a token of each level and a restricted token
// get, so a new route, a changed level, and a pattern that lost an anchor all fail this test.
test("every client route answers 401 without a token, 405 to another method, and 403 to a token below its level, a collector's route refuses a restricted token, no answer may be stored, and a path around a pattern stays behind Access", async () => {
	const { database, environment, token: ingestToken } = await prepareArchive()
	const { token: readToken } = await issueApiToken(database, { description: "Schublade app", level: "read" })
	const restrictedToken = await issueRestrictedToken(database)
	const bodies: Record<string, BodyInit | undefined> = {
		POST: JSON.stringify({ sha256: [SCANNED_INVOICE_SHA256] }),
		PUT: scannedInvoice,
	}
	const send = (method: string, path: string, token?: string) =>
		dispatch(
			new Request(`https://archive.test${path}`, {
				method,
				headers: {
					...(token !== undefined && { Authorization: `Bearer ${token}` }),
					...(method === "PUT" && { "Content-Length": String(scannedInvoice.byteLength) }),
				},
				body: bodies[method],
			}),
			environment,
		)
	const refusal = (response: Response, header: string) =>
		`${response.status} ${response.headers.get("Content-Type")} ${header}: ${response.headers.get(header)}`
	const admission = async (response: Response) =>
		response.status === 403 ? (await response.json<{ detail: string }>()).detail : response.status

	const answers: Record<string, unknown> = {}
	for (const { method, pattern } of clientRouteDefinitions) {
		const path = matchingPath(pattern)
		const withoutToken = await send(method, path)
		const otherMethod = await send(method === "GET" ? "POST" : "GET", path, readToken)
		const admissions = [
			await send(method, path, ingestToken),
			await send(method, path, readToken),
			await send(method, path, restrictedToken),
		]
		const [ingestAdmission, readAdmission, restrictedAdmission] = await Promise.all(admissions.map(admission))
		answers[`${method} ${path}`] = {
			withoutToken: refusal(withoutToken, "WWW-Authenticate"),
			otherMethod: refusal(otherMethod, "Allow"),
			ingestToken: ingestAdmission,
			readToken: readAdmission,
			restrictedToken: restrictedAdmission,
			cacheControl: [
				...new Set([withoutToken, otherMethod, ...admissions].map((response) => response.headers.get("Cache-Control"))),
			],
			aroundThePattern: [
				await (await send(method, `/x${path}`, readToken)).text(),
				await (await send(method, `${path}/x`, readToken)).text(),
			],
		}
	}

	const shared = (method: string) => ({
		withoutToken: "401 application/problem+json WWW-Authenticate: Bearer",
		otherMethod: `405 application/problem+json Allow: ${method}`,
		cacheControl: ["no-store"],
		aroundThePattern: ["Access denied: assertion_missing", "Access denied: assertion_missing"],
	})
	const readingRefused = "The API token does not permit reading the archive"
	const restrictedRefused =
		"This API token is restricted to a part of the archive. A collector needs an unrestricted token."
	const submissionRestrictedRefused =
		"This API token is restricted to a part of the archive. Adding documents needs an unrestricted token."
	expect(answers).toEqual({
		"GET /api/v1/authorization": { ...shared("GET"), ingestToken: 200, readToken: 200, restrictedToken: 200 },
		"GET /api/v1/changes": { ...shared("GET"), ingestToken: readingRefused, readToken: 200, restrictedToken: 200 },
		[`GET /api/v1/documents/${DOCUMENT_IDENTIFIER}/original`]: {
			...shared("GET"),
			ingestToken: readingRefused,
			readToken: 404,
			restrictedToken: 404,
		},
		"POST /api/v1/contents/lookup": {
			...shared("POST"),
			ingestToken: 200,
			readToken: 200,
			restrictedToken: restrictedRefused,
		},
		[`PUT /api/v1/submitted_documents/${SCANNED_INVOICE_SHA256}`]: {
			...shared("PUT"),
			ingestToken: 202,
			readToken: 200,
			restrictedToken: submissionRestrictedRefused,
		},
		[`PUT /api/v1/collected_documents/${SCANNED_INVOICE_SHA256}`]: {
			...shared("PUT"),
			ingestToken: 200,
			readToken: 200,
			restrictedToken: restrictedRefused,
		},
		[`GET /api/v1/documents/${DOCUMENT_IDENTIFIER}`]: {
			...shared("GET"),
			ingestToken: 404,
			readToken: 404,
			restrictedToken: restrictedRefused,
		},
	})
})

test("the archive changes socket needs an Access assertion", async () => {
	const { environment } = await prepareArchive()
	const upgrade = () => new Request("https://archive.test/api/archive_changes", { headers: { Upgrade: "websocket" } })

	const refused = await dispatch(upgrade(), environment)
	const admitted = await createRequestDispatcher(() => new Response("archive application"), true)(
		upgrade(),
		environment,
		context,
	)

	expect(await outcome(refused)).toEqual({ status: 403, body: "Access denied: assertion_missing" })
	expect(admitted.status).toBe(101)
	admitted.webSocket?.accept()
	admitted.webSocket?.close()
})
