import { applyD1Migrations, env, reset } from "cloudflare:test"
import { eq } from "drizzle-orm"
import { expect, inject, test } from "vitest"
import cloudStorageInvoice from "../../test_fixtures/collection_corpus/Cloud Storage/Rechnungen/Invoice-PLK-2026-004817.pdf"
import desktopInvoice from "../../test_fixtures/collection_corpus/Desktop/Invoice-PLK-2026-004817.pdf"
import downloadsInvoice from "../../test_fixtures/collection_corpus/Downloads/Invoice-PLK-2026-004817.pdf"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { deleteDocument } from "../archive/document_revision"
import { connectDatabase } from "../database/client"
import { contents, documents } from "../database/schema"
import { createInMemorySearchIndex } from "../search/in_memory_search_index"
import { acceptDocumentUpload, receiveDocumentUploads } from "./document_upload"

// The digests are the sha256 values of test_fixtures/expected_collection.json and of `sha256sum` on the fixture.
const INVOICE_SHA256 = "b60d823ff8fc9d5e3f8979eb7be7fd57d31bcb959dcc0ec5260c4daf6ec98150"
const SCANNED_INVOICE_SHA256 = "3551f8806c62a6b604bfbeab63ececeac46ee9df4e7db1ff5835377ff07ab0ed"

async function prepareArchive(failingWorkflowCreations = 0) {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const workflowInstances: Array<unknown> = []
	let remainingFailures = failingWorkflowCreations
	const workflow = {
		create: (options: unknown) => {
			if (remainingFailures-- > 0) return Promise.reject(new Error("The Workflows service is unavailable"))
			workflowInstances.push(options)
			return Promise.resolve()
		},
	}
	return { workflowInstances, environment: { ...env, DOCUMENT_INGESTION_WORKFLOW: workflow as unknown as Workflow } }
}

const pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
const jpegSignature = [0xff, 0xd8, 0xff, 0xe0]

function uploadRequest(files: Array<File>): Request {
	const formData = new FormData()
	for (const file of files) formData.append("files", file)
	return new Request("https://archive.test/api/documents", { method: "POST", body: formData })
}

test("receiveDocumentUploads identifies each file by its content and rejects an unsupported one", async () => {
	const { workflowInstances, environment } = await prepareArchive()
	const heicHeader = new Uint8Array([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])

	const response = await receiveDocumentUploads(
		environment,
		uploadRequest([
			new File([scannedInvoice], "invoice.pdf"),
			new File([heicHeader], "IMG_0001.heic", { type: "image/heic" }),
		]),
	)

	const [document] = await connectDatabase(env.DATABASE)
		.select({
			id: documents.id,
			storageObjectKey: documents.storageObjectKey,
			mimeType: documents.mimeType,
			status: documents.status,
		})
		.from(documents)
	expect({ status: response.status, body: await response.json(), document, workflowInstances }).toEqual({
		status: 200,
		body: {
			outcomes: [
				{ kind: "accepted", fileName: "invoice.pdf", documentId: document?.id },
				{
					kind: "rejected",
					fileName: "IMG_0001.heic",
					reason: "Only PDF, JPEG, PNG, and WebP files can be archived.",
				},
			],
		},
		document: {
			id: document?.id,
			storageObjectKey: `documents/${document?.id}/original.pdf`,
			mimeType: "application/pdf",
			status: "processing",
		},
		workflowInstances: [{ id: document?.id, params: { documentId: document?.id } }],
	})
})

test("receiveDocumentUploads rejects an oversized file and reports a failed one without losing the others", async () => {
	const { environment } = await prepareArchive(1)
	const oversizedPdf = new Uint8Array(25_000_001)
	oversizedPdf.set([0x25, 0x50, 0x44, 0x46, 0x2d])

	const response = await receiveDocumentUploads(
		environment,
		uploadRequest([
			new File([oversizedPdf], "scan.pdf", { type: "application/pdf" }),
			new File([new Uint8Array(pngSignature)], "photograph.png", { type: "image/png" }),
			new File([new Uint8Array(jpegSignature)], "receipt.jpg", { type: "image/jpeg" }),
		]),
	)

	const storedDocuments = await connectDatabase(env.DATABASE)
		.select({
			id: documents.id,
			mimeType: documents.mimeType,
			status: documents.status,
			failureReason: documents.failureReason,
		})
		.from(documents)
		.orderBy(documents.mimeType)
	expect({
		status: response.status,
		body: await response.json(),
		storedDocuments: storedDocuments.map(({ id: _id, ...document }) => document),
	}).toEqual({
		status: 200,
		body: {
			outcomes: [
				{ kind: "rejected", fileName: "scan.pdf", reason: "The file is larger than 25 MB" },
				{
					kind: "failed",
					fileName: "photograph.png",
					reason: "The archive could not store the file. Upload it again.",
				},
				{ kind: "accepted", fileName: "receipt.jpg", documentId: storedDocuments[0]?.id },
			],
		},
		storedDocuments: [
			{ mimeType: "image/jpeg", status: "processing", failureReason: null },
			{ mimeType: "image/png", status: "failed", failureReason: "processing_error" },
		],
	})
})

test("receiveDocumentUploads archives the first 20 files of a request and rejects the others", async () => {
	const { workflowInstances, environment } = await prepareArchive()
	const receipts = Array.from(
		{ length: 21 },
		(_, index) =>
			new File([new Uint8Array([...jpegSignature, index])], `receipt-${index + 1}.jpg`, { type: "image/jpeg" }),
	)

	const response = await receiveDocumentUploads(environment, uploadRequest(receipts))

	const { outcomes } = await response.json<{ outcomes: Array<{ kind: string; fileName: string }> }>()
	expect({
		acceptedFileNames: outcomes.filter((outcome) => outcome.kind === "accepted").map((outcome) => outcome.fileName),
		otherOutcomes: outcomes.filter((outcome) => outcome.kind !== "accepted"),
		storedDocuments: (await connectDatabase(env.DATABASE).select({ id: documents.id }).from(documents)).length,
		workflowInstances: workflowInstances.length,
	}).toEqual({
		acceptedFileNames: receipts.slice(0, 20).map((receipt) => receipt.name),
		otherOutcomes: [
			{
				kind: "rejected",
				fileName: "receipt-21.jpg",
				reason: "An upload accepts at most 20 files. Upload this file again.",
			},
		],
		storedDocuments: 20,
		workflowInstances: 20,
	})
})

test("receiveDocumentUploads answers a request without a multipart body with 400", async () => {
	const { environment } = await prepareArchive()

	const response = await receiveDocumentUploads(
		environment,
		new Request("https://archive.test/api/documents", { method: "POST", body: "not a form" }),
	)

	expect({ status: response.status, body: await response.json() }).toEqual({
		status: 400,
		body: { error: "Send the documents as multipart form fields named files" },
	})
})

test("receiveDocumentUploads refuses a request larger than 50 MB", async () => {
	const { environment } = await prepareArchive()

	const response = await receiveDocumentUploads(
		environment,
		uploadRequest([
			new File([new Uint8Array(24_000_000)], "first.pdf"),
			new File([new Uint8Array(24_000_000)], "second.pdf"),
			new File([new Uint8Array(2_000_000)], "third.pdf"),
		]),
	)

	expect({ status: response.status, body: await response.json() }).toEqual({
		status: 413,
		body: { error: "The upload is larger than 50 MB. Upload fewer files at once." },
	})
})

test("receiveDocumentUploads removes the stored original when its row cannot be recorded", async () => {
	const { environment } = await prepareArchive()
	const unavailableDatabase = {
		prepare: () => {
			throw new Error("D1 is unavailable")
		},
	}

	const response = await receiveDocumentUploads(
		{ ...environment, DATABASE: unavailableDatabase as unknown as D1Database },
		uploadRequest([new File([new Uint8Array(pngSignature)], "photograph.png", { type: "image/png" })]),
	)

	expect({
		body: await response.json(),
		storedObjects: (await env.DOCUMENT_STORAGE.list()).objects.map((object) => object.key),
	}).toEqual({
		body: {
			outcomes: [
				{
					kind: "failed",
					fileName: "photograph.png",
					reason: "The archive could not store the file. Upload it again.",
				},
			],
		},
		storedObjects: [],
	})
})

test("the same bytes become one document however many files carry them, and every other file names that document", async () => {
	const { workflowInstances, environment } = await prepareArchive()
	const database = connectDatabase(env.DATABASE)

	const firstResponse = await receiveDocumentUploads(
		environment,
		uploadRequest([
			new File([downloadsInvoice], "Invoice-PLK-2026-004817.pdf"),
			new File([desktopInvoice], "Invoice-PLK-2026-004817.pdf"),
		]),
	)
	const secondResponse = await receiveDocumentUploads(
		environment,
		uploadRequest([new File([cloudStorageInvoice], "Invoice-PLK-2026-004817.pdf")]),
	)

	const storedDocuments = await database
		.select({ id: documents.id, originalSha256: documents.originalSha256 })
		.from(documents)
	const documentId = storedDocuments[0]?.id
	expect({
		first: await firstResponse.json(),
		second: await secondResponse.json(),
		storedDocuments,
		contents: await database.select({ sha256: contents.sha256, documentId: contents.documentId }).from(contents),
		storedObjects: (await env.DOCUMENT_STORAGE.list()).objects.map((object) => object.key),
		workflowInstances: workflowInstances.length,
	}).toEqual({
		first: {
			outcomes: [
				{ kind: "accepted", fileName: "Invoice-PLK-2026-004817.pdf", documentId },
				{ kind: "already_archived", fileName: "Invoice-PLK-2026-004817.pdf", documentId },
			],
		},
		second: { outcomes: [{ kind: "already_archived", fileName: "Invoice-PLK-2026-004817.pdf", documentId }] },
		storedDocuments: [{ id: documentId, originalSha256: INVOICE_SHA256 }],
		contents: [{ sha256: INVOICE_SHA256, documentId }],
		storedObjects: [`documents/${documentId}/original.pdf`],
		workflowInstances: 1,
	})
})

test("a content whose document was deleted stays known and is archived again by the next upload", async () => {
	const { environment } = await prepareArchive()
	const database = connectDatabase(env.DATABASE)
	const { searchIndex } = createInMemorySearchIndex()
	const contentRows = () => database.select({ sha256: contents.sha256, documentId: contents.documentId }).from(contents)
	const first = await acceptDocumentUpload(environment, new File([scannedInvoice], "scan.pdf"))
	if (first.kind !== "accepted") throw new Error(`The first upload was ${first.kind}`)
	await database.update(documents).set({ status: "archived" }).where(eq(documents.id, first.documentId))

	await deleteDocument({ database, storage: env.DOCUMENT_STORAGE, searchIndex }, first.documentId)
	const afterDeletion = await contentRows()
	const second = await acceptDocumentUpload(environment, new File([scannedInvoice], "scan.pdf"))
	if (second.kind !== "accepted") throw new Error(`The second upload was ${second.kind}`)

	expect({
		afterDeletion,
		second,
		afterSecondUpload: await contentRows(),
		storedDocuments: (await database.select({ id: documents.id }).from(documents)).map((document) => document.id),
	}).toEqual({
		afterDeletion: [{ sha256: SCANNED_INVOICE_SHA256, documentId: null }],
		second: { kind: "accepted", fileName: "scan.pdf", documentId: second.documentId },
		afterSecondUpload: [{ sha256: SCANNED_INVOICE_SHA256, documentId: second.documentId }],
		storedDocuments: [second.documentId],
	})
	expect(second.documentId).not.toBe(first.documentId)
})

test("the loser of two concurrent uploads of the same bytes is failed, not left processing, when its cleanup fails", async () => {
	const { workflowInstances, environment } = await prepareArchive()
	const failingDeletion = {
		prepare: (query: string) => {
			if (query.startsWith('delete from "documents"')) throw new Error("D1 is unavailable")
			return env.DATABASE.prepare(query)
		},
		batch: (statements: Array<D1PreparedStatement>) => env.DATABASE.batch(statements),
	}
	const racingEnvironment = { ...environment, DATABASE: failingDeletion as unknown as D1Database }

	const outcomes = await Promise.allSettled([
		acceptDocumentUpload(racingEnvironment, new File([downloadsInvoice], "Invoice-PLK-2026-004817.pdf")),
		acceptDocumentUpload(racingEnvironment, new File([desktopInvoice], "Invoice-PLK-2026-004817.pdf")),
	])

	const database = connectDatabase(env.DATABASE)
	const storedDocuments = await database
		.select({ id: documents.id, status: documents.status, failureReason: documents.failureReason })
		.from(documents)
	const [holder] = await database.select({ documentId: contents.documentId }).from(contents)
	expect({
		outcomes: outcomes.map((outcome) => (outcome.status === "fulfilled" ? outcome.value.kind : outcome.status)).sort(),
		holder: storedDocuments.find((document) => document.id === holder?.documentId)?.status,
		loser: storedDocuments
			.filter((document) => document.id !== holder?.documentId)
			.map(({ status, failureReason }) => ({ status, failureReason })),
		workflowInstances: workflowInstances.length,
	}).toEqual({
		outcomes: ["accepted", "rejected"],
		holder: "processing",
		loser: [{ status: "failed", failureReason: "processing_error" }],
		workflowInstances: 1,
	})
})
