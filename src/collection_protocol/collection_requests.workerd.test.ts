import { applyD1Migrations, createExecutionContext, env, reset } from "cloudflare:test"
import { eq } from "drizzle-orm"
import { expect, inject, test } from "vitest"
import downloadsInvoice from "../../test_fixtures/collection_corpus/Downloads/Invoice-PLK-2026-004817.pdf"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { deleteDocument } from "../archive/document_revision"
import { issueApiToken } from "../authentication/api_tokens"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { acceptDocumentUpload } from "../ingestion/document_upload"
import { createRequestDispatcher } from "../request_dispatch"
import { createInMemorySearchIndex } from "../search/in_memory_search_index"

// The digest of Invoice-PLK-2026-004817.pdf, from test_fixtures/expected_collection.json.
const INVOICE_SHA256 = "b60d823ff8fc9d5e3f8979eb7be7fd57d31bcb959dcc0ec5260c4daf6ec98150"
// The digest of test_fixtures/documents/electricity_invoice_scanned.pdf.
const SCANNED_INVOICE_SHA256 = "3551f8806c62a6b604bfbeab63ececeac46ee9df4e7db1ff5835377ff07ab0ed"
const UNKNOWN_SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"
const UNKNOWN_DOCUMENT_ID = "00000000-0000-4000-8000-000000000000"

const context = createExecutionContext()
const dispatchWithAccess = createRequestDispatcher(() => new Response("archive application"), false)

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
	const { token } = await issueApiToken(database, { description: "Laptop collector", level: "ingest" })
	const collect = (method: string, path: string, body?: BodyInit) =>
		dispatchWithAccess(
			new Request(`https://archive.test${path}`, { method, headers: { Authorization: `Bearer ${token}` }, body }),
			environment,
			context,
		)
	return { database, environment, workflowInstances, collect }
}

async function answer(response: Response) {
	return {
		status: response.status,
		contentType: response.headers.get("Content-Type"),
		location: response.headers.get("Location"),
		body: await response.json(),
	}
}

test("POST /api/v1/contents/lookup answers absent, present, and deleted in request order, and refuses a malformed body", async () => {
	const { database, environment, collect } = await prepareArchive()
	const present = await acceptDocumentUpload(environment, new File([downloadsInvoice], "invoice.pdf"))
	const deleted = await acceptDocumentUpload(environment, new File([scannedInvoice], "scan.pdf"))
	if (present.kind !== "accepted" || deleted.kind !== "accepted") throw new Error("The uploads were not accepted")
	await database.update(documents).set({ status: "archived" }).where(eq(documents.id, deleted.documentId))
	await deleteDocument(
		{ database, storage: env.DOCUMENT_STORAGE, searchIndex: createInMemorySearchIndex().searchIndex },
		deleted.documentId,
	)

	const lookup = await collect(
		"POST",
		"/api/v1/contents/lookup",
		JSON.stringify({ sha256: [UNKNOWN_SHA256, INVOICE_SHA256, SCANNED_INVOICE_SHA256] }),
	)
	const malformed = await collect("POST", "/api/v1/contents/lookup", JSON.stringify({ sha256: ["XYZ"] }))
	const notJson = await collect("POST", "/api/v1/contents/lookup", "sha256")

	expect({ lookup: await answer(lookup), malformed: await answer(malformed), notJson: await answer(notJson) }).toEqual({
		lookup: {
			status: 200,
			contentType: "application/json",
			location: null,
			body: {
				contents: [
					{ sha256: UNKNOWN_SHA256, state: "absent" },
					{ sha256: INVOICE_SHA256, state: "present", document_id: present.documentId },
					{ sha256: SCANNED_INVOICE_SHA256, state: "deleted" },
				],
			},
		},
		malformed: {
			status: 400,
			contentType: "application/problem+json",
			location: null,
			body: {
				type: "about:blank",
				title: "Bad Request",
				status: 400,
				detail: "✖ Invalid string: must match pattern /^[0-9a-f]{64}$/\n  → at sha256[0]",
			},
		},
		notJson: {
			status: 400,
			contentType: "application/problem+json",
			location: null,
			body: {
				type: "about:blank",
				title: "Bad Request",
				status: 400,
				detail: "Send a JSON object whose sha256 member lists the digests to look up",
			},
		},
	})
})

test("PUT /api/v1/contents/{sha256} archives new bytes with 202 and answers 200 for bytes a document holds", async () => {
	const { database, workflowInstances, collect } = await prepareArchive()

	const first = await collect("PUT", `/api/v1/contents/${INVOICE_SHA256}`, downloadsInvoice)
	const second = await collect("PUT", `/api/v1/contents/${INVOICE_SHA256}`, downloadsInvoice)

	const [document] = await database
		.select({ id: documents.id, originalSha256: documents.originalSha256, byteSize: documents.byteSize })
		.from(documents)
	const documentId = document?.id
	const expectedAnswer = (status: number) => ({
		status,
		contentType: "application/json",
		location: `/api/v1/documents/${documentId}`,
		body: { document_id: documentId, status: "processing", failure_reason: null },
	})
	expect({
		first: await answer(first),
		second: await answer(second),
		document,
		workflowInstances: workflowInstances.length,
	}).toEqual({
		first: expectedAnswer(202),
		second: expectedAnswer(200),
		document: { id: documentId, originalSha256: INVOICE_SHA256, byteSize: 37713 },
		workflowInstances: 1,
	})
})

test("PUT /api/v1/contents/{sha256} refuses a digest mismatch, an unaccepted file, and an oversized body without storing anything", async () => {
	const { database, collect } = await prepareArchive()
	const oversizedPdf = new Uint8Array(25_000_001)
	oversizedPdf.set([0x25, 0x50, 0x44, 0x46, 0x2d])

	const mismatch = await collect("PUT", `/api/v1/contents/${UNKNOWN_SHA256}`, downloadsInvoice)
	const unaccepted = await collect(
		"PUT",
		// The digest of the five bytes of the body.
		"/api/v1/contents/185f8db32271fe25f561a6fc938b2e264306ec304eda518007d1764826381969",
		new TextEncoder().encode("Hello"),
	)
	const oversized = await collect("PUT", `/api/v1/contents/${UNKNOWN_SHA256}`, oversizedPdf)

	expect({
		mismatch: await answer(mismatch),
		unaccepted: await answer(unaccepted),
		oversized: await answer(oversized),
		storedDocuments: await database.select({ id: documents.id }).from(documents),
		storedObjects: (await env.DOCUMENT_STORAGE.list()).objects,
	}).toEqual({
		mismatch: {
			status: 422,
			contentType: "application/problem+json",
			location: null,
			body: {
				type: "about:blank",
				title: "Unprocessable Content",
				status: 422,
				detail: `The body has the SHA-256 ${INVOICE_SHA256}, not the one in the path`,
			},
		},
		unaccepted: {
			status: 415,
			contentType: "application/problem+json",
			location: null,
			body: {
				type: "about:blank",
				title: "Unsupported Media Type",
				status: 415,
				detail: "Only PDF, JPEG, PNG, and WebP files can be archived.",
			},
		},
		oversized: {
			status: 413,
			contentType: "application/problem+json",
			location: null,
			body: {
				type: "about:blank",
				title: "Content Too Large",
				status: 413,
				detail: "The file is larger than 25 MB",
			},
		},
		storedDocuments: [],
		storedObjects: [],
	})
})

test("GET /api/v1/documents/{id} reports the status with its failure reason, and 404 for an unknown document", async () => {
	const { database, environment, collect } = await prepareArchive()
	const upload = await acceptDocumentUpload(environment, new File([scannedInvoice], "scan.pdf"))
	if (upload.kind !== "accepted") throw new Error(`The upload was ${upload.kind}`)
	await database
		.update(documents)
		.set({ status: "failed", failureReason: "unreadable_file" })
		.where(eq(documents.id, upload.documentId))

	const failed = await collect("GET", `/api/v1/documents/${upload.documentId}`)
	const unknown = await collect("GET", `/api/v1/documents/${UNKNOWN_DOCUMENT_ID}`)

	expect({ failed: await answer(failed), unknown: await answer(unknown) }).toEqual({
		failed: {
			status: 200,
			contentType: "application/json",
			location: `/api/v1/documents/${upload.documentId}`,
			body: { document_id: upload.documentId, status: "failed", failure_reason: "unreadable_file" },
		},
		unknown: {
			status: 404,
			contentType: "application/problem+json",
			location: null,
			body: {
				type: "about:blank",
				title: "Not Found",
				status: 404,
				detail: `No document has the identifier ${UNKNOWN_DOCUMENT_ID}`,
			},
		},
	})
})
