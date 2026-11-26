import { applyD1Migrations, createExecutionContext, env, reset } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { issueApiToken } from "../authentication/api_tokens"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { createRequestDispatcher } from "../request_dispatch"

// The digest of test_fixtures/documents/electricity_invoice_scanned.pdf.
const SCANNED_INVOICE_SHA256 = "3551f8806c62a6b604bfbeab63ececeac46ee9df4e7db1ff5835377ff07ab0ed"
const submittedText = new TextEncoder().encode(
	"## Page 1\n\nStadtwerke Talbrück GmbH\nJahresabrechnung Strom 2025-2026\n",
)
// The archive checks only the leading bytes of a thumbnail.
const submittedThumbnail = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9])

const context = createExecutionContext()

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
	const { token } = await issueApiToken(database, { description: "Schublade on the iPhone", level: "ingest" })
	return { database, environment, workflowInstances, token }
}

/** The body of a client that read the text and drew the thumbnail, as one request over HTTP carries it. */
function receptionRequest(path: string, headers: Record<string, string>): Request {
	const body = new Blob([submittedText, submittedThumbnail, scannedInvoice])
	return new Request(`https://archive.test${path}`, {
		method: "PUT",
		headers: {
			...headers,
			"Content-Length": String(body.size),
			"Schublade-Text-Byte-Count": String(submittedText.byteLength),
			"Schublade-Thumbnail-Byte-Count": String(submittedThumbnail.byteLength),
			"Schublade-Page-Count": "2",
		},
		body: body.stream(),
	})
}

async function storedObjects() {
	const { objects } = await env.DOCUMENT_STORAGE.list({ include: ["httpMetadata"] })
	return objects.map(({ key, size, httpMetadata }) => ({
		name: key.split("/").at(-1),
		size,
		contentType: httpMetadata?.contentType,
	}))
}

test("PUT /api/v1/submitted_documents/{sha256} stores the original, the text, and the thumbnail with 202, and the same request again answers 200 and writes nothing", async () => {
	const { database, environment, workflowInstances, token } = await prepareArchive()
	const dispatch = createRequestDispatcher(() => new Response("archive application"), false)
	const send = () =>
		dispatch(
			receptionRequest(`/api/v1/submitted_documents/${SCANNED_INVOICE_SHA256}`, { Authorization: `Bearer ${token}` }),
			environment,
			context,
		)

	const first = await send()
	const objectsAfterFirst = await storedObjects()
	const second = await send()

	const [document] = await database
		.select({ id: documents.id, byteSize: documents.byteSize, pageCount: documents.pageCount })
		.from(documents)
	expect({
		first: { status: first.status, body: await first.json() },
		second: { status: second.status, body: await second.json() },
		objectsAfterFirst,
		objectsAfterSecond: await storedObjects(),
		document,
		workflowInstances: workflowInstances.length,
	}).toEqual({
		first: { status: 202, body: { document_id: document?.id, status: "processing", failure_reason: null } },
		second: { status: 200, body: { document_id: document?.id, status: "processing", failure_reason: null } },
		objectsAfterFirst: [
			{ name: "original.pdf", size: 190941, contentType: "application/pdf" },
			{ name: "submitted_text.md", size: 70, contentType: "text/markdown; charset=utf-8" },
			{ name: "thumbnail.jpg", size: 12, contentType: "image/jpeg" },
		],
		objectsAfterSecond: objectsAfterFirst,
		document: { id: document?.id, byteSize: 190941, pageCount: 2 },
		workflowInstances: 1,
	})
})

test("PUT /api/submitted_documents/{sha256} from a member's browser refuses an original whose digest differs from the path with 422 and stores nothing", async () => {
	const { database, environment } = await prepareArchive()
	const dispatchAsMember = createRequestDispatcher(() => new Response("archive application"), true)

	const response = await dispatchAsMember(
		receptionRequest(`/api/submitted_documents/${"0".repeat(64)}`, {}),
		environment,
		context,
	)

	expect({
		status: response.status,
		body: await response.json(),
		storedDocuments: await database.select({ id: documents.id }).from(documents),
		storedObjects: await storedObjects(),
	}).toEqual({
		status: 422,
		body: {
			type: "about:blank",
			title: "Unprocessable Content",
			status: 422,
			detail: "The original does not have the SHA-256 in the path",
		},
		storedDocuments: [],
		storedObjects: [],
	})
})
