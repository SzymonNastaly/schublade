import { applyD1Migrations, env, reset } from "cloudflare:test"
import { eq } from "drizzle-orm"
import { expect, inject, test } from "vitest"
import scannedInvoice from "../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { issueApiToken } from "./authentication/api_tokens"
import { connectDatabase } from "./database/client"
import { apiTokens, documents } from "./database/schema"
import { createRequestDispatcher } from "./request_dispatch"

const dispatch = createRequestDispatcher(() => new Response("archive application"), false)

async function prepareArchive() {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	const workflowInstances: Array<unknown> = []
	const workflow = {
		create: (options: unknown) => {
			workflowInstances.push(options)
			return Promise.resolve()
		},
	}
	const environment = {
		...env,
		ACCESS_TEAM_DOMAIN: "archive-test.cloudflareaccess.com",
		ACCESS_AUD: "4714c1358e65fe4b408ad6d432a5f878f08194bdb4752441fd56faefa9b2b6f2",
		DOCUMENT_INGESTION_WORKFLOW: workflow as unknown as Workflow,
	}
	const { token } = await issueApiToken(database, { description: "Network scanner", level: "ingest" })
	return { database, environment, workflowInstances, token }
}

function uploadRequest(path: string, headers: Record<string, string>): Request {
	const formData = new FormData()
	formData.append("files", new File([scannedInvoice], "scan.pdf"))
	return new Request(`https://archive.test${path}`, { method: "POST", headers, body: formData })
}

async function outcome(response: Response) {
	return { status: response.status, body: await response.text() }
}

test("POST /api/documents/ingest archives the files of a request with an ingest token and no Access assertion", async () => {
	const { database, environment, workflowInstances, token } = await prepareArchive()

	const response = await dispatch(
		uploadRequest("/api/documents/ingest", { Authorization: `Bearer ${token}` }),
		environment,
	)

	const [document] = await database.select({ id: documents.id, status: documents.status }).from(documents)
	expect({ status: response.status, body: await response.json(), document, workflowInstances }).toEqual({
		status: 200,
		body: { outcomes: [{ kind: "accepted", fileName: "scan.pdf", documentId: document?.id }] },
		document: { id: document?.id, status: "processing" },
		workflowInstances: [{ id: document?.id, params: { documentId: document?.id } }],
	})
})

test("POST /api/documents/ingest refuses a missing, unknown, or read-only token without storing a file", async () => {
	const { database, environment } = await prepareArchive()
	const unknownToken = `schublade_${"A".repeat(43)}`
	const { token: readToken, listing } = await issueApiToken(database, { description: "Reader", level: "ingest" })
	await database
		.update(apiTokens)
		.set({ authorizationScope: { level: "read" } })
		.where(eq(apiTokens.id, listing.id))

	const responses = [
		await dispatch(uploadRequest("/api/documents/ingest", {}), environment),
		await dispatch(uploadRequest("/api/documents/ingest", { Authorization: `Bearer ${unknownToken}` }), environment),
		await dispatch(uploadRequest("/api/documents/ingest", { Authorization: `Bearer ${readToken}` }), environment),
	]

	expect({
		outcomes: await Promise.all(responses.map(outcome)),
		challenge: responses[0]?.headers.get("WWW-Authenticate"),
		storedDocuments: await database.select().from(documents),
		storedObjects: (await env.DOCUMENT_STORAGE.list()).objects,
	}).toEqual({
		outcomes: [
			{ status: 401, body: '{"error":"Send a valid API token in the Authorization header"}' },
			{ status: 401, body: '{"error":"Send a valid API token in the Authorization header"}' },
			{ status: 403, body: '{"error":"The API token does not permit ingesting documents"}' },
		],
		challenge: "Bearer",
		storedDocuments: [],
		storedObjects: [],
	})
})

test("every other path requires an Access assertion even with a valid token, and cross-site writes are refused first", async () => {
	const { environment, token } = await prepareArchive()
	const bearer = { Authorization: `Bearer ${token}` }

	const responses = [
		await dispatch(uploadRequest("/api/documents", bearer), environment),
		await dispatch(uploadRequest("/api/documents/ingest/", bearer), environment),
		await dispatch(uploadRequest("/api/documents/ingestion", bearer), environment),
		await dispatch(new Request("https://archive.test/settings", { headers: bearer }), environment),
		await dispatch(
			uploadRequest("/api/documents/ingest", { ...bearer, Origin: "https://elsewhere.example" }),
			environment,
		),
	]

	expect(await Promise.all(responses.map(outcome))).toEqual([
		{ status: 403, body: "Access denied: assertion_missing" },
		{ status: 403, body: "Access denied: assertion_missing" },
		{ status: 403, body: "Access denied: assertion_missing" },
		{ status: 403, body: "Access denied: assertion_missing" },
		{ status: 403, body: "Cross-site request refused: https://elsewhere.example" },
	])
})

test("the archive changes socket needs an Access assertion", async () => {
	const { environment } = await prepareArchive()
	const upgrade = () => new Request("https://archive.test/api/archive_changes", { headers: { Upgrade: "websocket" } })

	const refused = await dispatch(upgrade(), environment)
	const admitted = await createRequestDispatcher(() => new Response("archive application"), true)(
		upgrade(),
		environment,
	)

	expect(await outcome(refused)).toEqual({ status: 403, body: "Access denied: assertion_missing" })
	expect(admitted.status).toBe(101)
	admitted.webSocket?.accept()
	admitted.webSocket?.close()
})
