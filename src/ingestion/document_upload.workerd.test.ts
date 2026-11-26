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
import { acceptDocumentUpload } from "./document_upload"

// The digests are the sha256 values of test_fixtures/expected_collection.json and of `sha256sum` on the fixture.
const INVOICE_SHA256 = "b60d823ff8fc9d5e3f8979eb7be7fd57d31bcb959dcc0ec5260c4daf6ec98150"
const SCANNED_INVOICE_SHA256 = "3551f8806c62a6b604bfbeab63ececeac46ee9df4e7db1ff5835377ff07ab0ed"

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

test("the same bytes become one document however many files carry them, and every other file names that document", async () => {
	const { workflowInstances, environment } = await prepareArchive()
	const database = connectDatabase(env.DATABASE)

	const outcomes = [
		await acceptDocumentUpload(environment, new File([downloadsInvoice], "Invoice-PLK-2026-004817.pdf")),
		await acceptDocumentUpload(environment, new File([desktopInvoice], "Invoice-PLK-2026-004817.pdf")),
		await acceptDocumentUpload(environment, new File([cloudStorageInvoice], "Invoice-PLK-2026-004817.pdf")),
	]

	const storedDocuments = await database
		.select({ id: documents.id, originalSha256: documents.originalSha256 })
		.from(documents)
	const documentId = storedDocuments[0]?.id
	expect({
		outcomes,
		storedDocuments,
		contents: await database.select({ sha256: contents.sha256, documentId: contents.documentId }).from(contents),
		storedObjects: (await env.DOCUMENT_STORAGE.list()).objects.map((object) => object.key),
		workflowInstances: workflowInstances.length,
	}).toEqual({
		outcomes: [
			{ kind: "accepted", fileName: "Invoice-PLK-2026-004817.pdf", documentId },
			{ kind: "already_archived", fileName: "Invoice-PLK-2026-004817.pdf", documentId },
			{ kind: "already_archived", fileName: "Invoice-PLK-2026-004817.pdf", documentId },
		],
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
