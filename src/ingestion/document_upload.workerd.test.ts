import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { receiveDocumentUploads } from "./document_upload"

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
					reason: "The content of the file is not one of application/pdf, image/jpeg, image/png, image/webp",
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
		.select({ id: documents.id, mimeType: documents.mimeType, status: documents.status })
		.from(documents)
		.orderBy(documents.mimeType)
	expect({
		status: response.status,
		body: await response.json(),
		storedDocuments: storedDocuments.map(({ mimeType, status }) => ({ mimeType, status })),
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
			{ mimeType: "image/jpeg", status: "processing" },
			{ mimeType: "image/png", status: "failed" },
		],
	})
})

test("receiveDocumentUploads archives the first 20 files of a request and rejects the others", async () => {
	const { workflowInstances, environment } = await prepareArchive()
	const receipts = Array.from(
		{ length: 21 },
		(_, index) => new File([new Uint8Array(jpegSignature)], `receipt-${index + 1}.jpg`, { type: "image/jpeg" }),
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
