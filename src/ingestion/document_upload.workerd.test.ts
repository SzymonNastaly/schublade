import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { receiveDocumentUploads } from "./document_upload"

async function prepareArchive() {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const workflowInstances: Array<unknown> = []
	const workflow = {
		create: (options: unknown) => {
			workflowInstances.push(options)
			return Promise.resolve()
		},
	}
	return { workflowInstances, environment: { ...env, DOCUMENT_INGESTION_WORKFLOW: workflow as unknown as Workflow } }
}

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
