import { applyD1Migrations, env, reset } from "cloudflare:test"
import { eq } from "drizzle-orm"
import { expect, inject, test } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import expectedExtraction from "../../test_fixtures/documents/expected_extraction.json"
import recording from "../../test_fixtures/inference_recordings/electricity_invoice_scanned.json"
import { queryDocumentListing } from "../archive/document_listing"
import { connectDatabase } from "../database/client"
import { categories, documents, extractedFields, senders, tags } from "../database/schema"
import { ingestDocument, retryDocumentIngestion } from "./document_ingestion"
import { contentObjectKey } from "./source_file"
import type { WorkflowStep } from "cloudflare:workers"
import type { SearchIndex } from "../search/document_indexing"

// Replays the Workers AI responses recorded for this fixture, so the test makes no billed request.
const recordedRuntime = {
	toMarkdown: () => Promise.resolve(recording.markdownConversion),
	run: (model: string) =>
		Promise.resolve(
			model === "@cf/moondream/moondream3.1-9B-A2B"
				? new Response(recording.textRecognitionEventStream).body
				: recording.classificationResponse,
		),
}

// Records each AI Search upload instead of sending it to the billed service.
const searchIndexUploads: Array<{ name: string; content: string; metadata: unknown }> = []
const recordingSearchIndex: SearchIndex = {
	search: () => Promise.reject(new Error("Ingestion does not search")),
	items: {
		upload: (name, content, options) => {
			searchIndexUploads.push({ name, content: String(content), metadata: options?.metadata })
			return Promise.resolve({ id: name, key: name, status: "queued" })
		},
		list: () => Promise.resolve({ result: [] }),
		delete: () => Promise.reject(new Error("Ingestion does not delete")),
	},
}

const recordedEnvironment = {
	...env,
	AI_RUNTIME: recordedRuntime as unknown as Ai,
	CLASSIFICATION_MODEL: "@cf/deepseek-ai/deepseek-v4.1-flash-1017",
	SEARCH_INDEX: recordingSearchIndex,
}

// Runs each step once and passes its result through structured cloning, as Workflows persist it.
function createRecordingStep(beforeStep: (name: string) => Promise<void> = () => Promise.resolve()) {
	const stepNames: Array<string> = []
	const step = {
		async do(name: string, _configuration: unknown, callback: () => Promise<unknown>) {
			stepNames.push(name)
			await beforeStep(name)
			return structuredClone(await callback())
		},
	}
	return { stepNames, step: step as unknown as Pick<WorkflowStep, "do"> }
}

async function storeScannedInvoice(documentId: string, original: Uint8Array | ArrayBuffer = scannedInvoice) {
	await reset()
	searchIndexUploads.length = 0
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	const storageObjectKey = `documents/${documentId}/original.pdf`
	await env.DOCUMENT_STORAGE.put(storageObjectKey, original)
	await database.insert(documents).values({
		id: documentId,
		storageObjectKey,
		mimeType: "application/pdf",
		byteSize: original.byteLength,
		status: "processing",
	})
	return database
}

test("ingestDocument recognizes, classifies, archives, and indexes a scanned invoice one step per unit", async () => {
	const documentId = "0f4c2b8e-5d71-4a39-9e62-3b1d7c8a4f10"
	const database = await storeScannedInvoice(documentId)
	const { stepNames, step } = createRecordingStep()

	const outcome = await ingestDocument(step, recordedEnvironment, documentId)

	expect(stepNames).toEqual([
		"extract text",
		"record status recognizing_text",
		"recognize page 1",
		"store markdown",
		"record status classifying",
		"classify document",
		"archive document",
		"index document",
	])
	expect(outcome).toEqual({
		documentId,
		recognizedPageCount: 1,
		classificationModel: "@cf/deepseek-ai/deepseek-v4.1-flash-1017",
		classificationInputTokens: 2504,
		classificationOutputTokens: 1756,
	})
	const expected = expectedExtraction.documents.find(
		(document) => document.file_name === "electricity_invoice_scanned.pdf",
	)?.fields
	expect(await queryDocumentListing(database)).toEqual([
		{
			id: documentId,
			status: "archived",
			title: "Stadtwerke Talbrück Invoice Electricity Consumption September 2025 to August 2026",
			documentDate: "2026-09-22",
			senderName: "Stadtwerke Talbrück GmbH",
			categoryName: "Invoice",
			personMemberId: null,
			personName: null,
			summary:
				"This is an annual electricity consumption statement from Stadtwerke Talbrück for the joint supply address Am Lindenhang 7, covering 1 September 2025 to 31 August 2026. It records a consumption of 2,691 kWh and requires a Nachzahlung of €72.09 by 6 October 2026.",
			mimeType: "application/pdf",
			pageCount: 1,
			verificationReason: "new_taxonomy_record",
			tagNames: [],
			fields: [
				{ fieldKey: "amount", value: expected?.amount?.value, confidence: 0.99 },
				{ fieldKey: "currency", value: expected?.currency?.value, confidence: 0.99 },
				{ fieldKey: "due_date", value: expected?.due_date?.value, confidence: 0.99 },
				{ fieldKey: "iban", value: expected?.iban?.value, confidence: 0.99 },
				{ fieldKey: "invoice_number", value: expected?.invoice_number?.value, confidence: 0.99 },
				// The model read the contract account number Vertragskonto as a policy number.
				{ fieldKey: "policy_number", value: "300 418 225", confidence: 0.95 },
			],
		},
	])
	const markdown = await (await env.DOCUMENT_STORAGE.get(contentObjectKey(documentId)))?.text()
	expect(markdown?.split("\n").filter((line) => line.includes("Nachzahlungsbetrag"))).toEqual([
		"Bitte überweisen Sie den Nachzahlungsbetrag von 72,09 € bis zum 06.10.2026 unter Angabe der Rechnungsnummer JA-2026-0381547 das folgende Konto:",
	])
	const [sender] = await database.select({ id: senders.id, confirmedAt: senders.confirmedAt }).from(senders)
	const [category] = await database.select({ id: categories.id, confirmedAt: categories.confirmedAt }).from(categories)
	// The classifier's new sender awaits a member, and the standard category Invoice does not.
	expect([sender?.confirmedAt === null, category?.confirmedAt === null]).toEqual([true, false])
	expect(searchIndexUploads.map((upload) => ({ ...upload, content: upload.content.split("\n").slice(0, 4) }))).toEqual([
		{
			name: `${documentId}.md`,
			content: [
				"# Stadtwerke Talbrück Invoice Electricity Consumption September 2025 to August 2026",
				"Sender: Stadtwerke Talbrück GmbH",
				"",
				"This is an annual electricity consumption statement from Stadtwerke Talbrück for the joint supply address Am Lindenhang 7, covering 1 September 2025 to 31 August 2026. It records a consumption of 2,691 kWh and requires a Nachzahlung of €72.09 by 6 October 2026.",
			],
			metadata: {
				person: "household",
				sender: sender?.id,
				category: category?.id,
				document_date: "2026-09-22T00:00:00Z",
			},
		},
	])
	expect(searchIndexUploads[0]?.content.endsWith(`${markdown?.trim()}\n`)).toBe(true)
})

test("ingestDocument writes nothing when the document leaves classifying before the archive step", async () => {
	const documentId = "3c9a7e15-2b84-4f06-8d1e-5a6f0b9c2e47"
	const database = await storeScannedInvoice(documentId)
	await database
		.insert(extractedFields)
		.values({ documentId, fieldKey: "amount", fieldType: "number", valueNumber: 10 })
	const { step } = createRecordingStep(async (name) => {
		if (name === "archive document") {
			await database.update(documents).set({ status: "failed" }).where(eq(documents.id, documentId))
		}
	})

	await expect(ingestDocument(step, recordedEnvironment, documentId)).rejects.toThrow(
		`Document ${documentId} left the classifying status before it was archived`,
	)
	expect({
		documents: await database.select({ status: documents.status, title: documents.title }).from(documents),
		fields: await database
			.select({ fieldKey: extractedFields.fieldKey, valueNumber: extractedFields.valueNumber })
			.from(extractedFields),
		senders: await database.select({ name: senders.name }).from(senders),
		categories: await database.select({ name: categories.name }).from(categories),
		tags: await database.select({ name: tags.name }).from(tags),
	}).toEqual({
		documents: [{ status: "failed", title: null }],
		fields: [{ fieldKey: "amount", valueNumber: 10 }],
		senders: [],
		categories: [],
		tags: [],
	})
})

// PDFium rebuilds the missing cross-reference table, so these objects are a valid file of blank pages.
function blankPdf(pageCount: number): Uint8Array {
	const pageObjects = Array.from(
		{ length: pageCount },
		(_, index) => `${index + 3} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>\nendobj\n`,
	)
	const kids = pageObjects.map((_, index) => `${index + 3} 0 R`).join(" ")
	return new TextEncoder().encode(
		`%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Count ${pageCount} /Kids [${kids}] >>\nendobj\n${pageObjects.join("")}trailer\n<< /Root 1 0 R >>\n%%EOF\n`,
	)
}

test("ingestDocument records why a document failed", async () => {
	const documentId = "7d2e9b41-6c3a-4f18-b5d7-2a8c1e4f9b03"
	const failureAfter = async (original: Uint8Array | ArrayBuffer, runtime: unknown) => {
		const database = await storeScannedInvoice(documentId, original)
		const { stepNames, step } = createRecordingStep()
		const message = await ingestDocument(step, { ...recordedEnvironment, AI_RUNTIME: runtime as Ai }, documentId).catch(
			(error: Error) => error.message,
		)
		const [document] = await database
			.select({ status: documents.status, failureReason: documents.failureReason })
			.from(documents)
		return { ...document, message, stepNames }
	}
	const emptyConversion = { toMarkdown: () => Promise.resolve({ format: "markdown", data: "" }) }
	const unavailableConversion = { toMarkdown: () => Promise.reject(new Error("The conversion service is unavailable")) }

	expect({
		longScan: await failureAfter(blankPdf(51), emptyConversion),
		damagedFile: await failureAfter(new TextEncoder().encode("%PDF-1.7\nnot a document"), unavailableConversion),
		serviceError: await failureAfter(scannedInvoice, unavailableConversion),
	}).toEqual({
		longScan: {
			status: "failed",
			failureReason: "page_limit_exceeded",
			message: "The document has 51 pages without a readable text layer, and at most 50 are transcribed",
			stepNames: ["extract text", "record status failed"],
		},
		damagedFile: {
			status: "failed",
			failureReason: "unreadable_file",
			message: "PDFium could not open the document, error code 3",
			stepNames: ["extract text", "record status failed"],
		},
		serviceError: {
			status: "failed",
			failureReason: "processing_error",
			message: "The conversion service is unavailable",
			stepNames: ["extract text", "record status failed"],
		},
	})
})

const failedDocumentId = "c4a81f6e-9d37-4b52-8e10-6f3b7d2a5c98"

async function storeFailedDocument() {
	const database = await storeScannedInvoice(failedDocumentId)
	await database
		.update(documents)
		.set({ status: "failed", failureReason: "processing_error" })
		.where(eq(documents.id, failedDocumentId))
	const readDocument = () =>
		database.select({ status: documents.status, failureReason: documents.failureReason }).from(documents)
	return { readDocument }
}

test("retryDocumentIngestion lets one of two retries through and starts one workflow under a new identifier", async () => {
	const { readDocument } = await storeFailedDocument()
	const instances: Array<{ id: string; params: unknown }> = []
	const workflow = {
		create: (instance: { id: string; params: unknown }) => {
			instances.push(instance)
			return Promise.resolve()
		},
	}
	const environment = { ...env, DOCUMENT_INGESTION_WORKFLOW: workflow as unknown as Workflow }

	const attempts = await Promise.allSettled([
		retryDocumentIngestion(environment, failedDocumentId),
		retryDocumentIngestion(environment, failedDocumentId),
	])

	expect({
		refusals: attempts.flatMap((attempt) => (attempt.status === "rejected" ? [(attempt.reason as Error).message] : [])),
		documents: await readDocument(),
		parameters: instances.map((instance) => instance.params),
		instanceIdentifierIsNew: instances.every((instance) => instance.id !== failedDocumentId),
	}).toEqual({
		refusals: [`Document ${failedDocumentId} has not failed, so it cannot be retried`],
		documents: [{ status: "processing", failureReason: null }],
		parameters: [{ documentId: failedDocumentId }],
		instanceIdentifierIsNew: true,
	})
})

test("retryDocumentIngestion leaves the document failed when its workflow cannot start", async () => {
	const { readDocument } = await storeFailedDocument()
	const workflow = { create: () => Promise.reject(new Error("The Workflows service is unavailable")) }

	await expect(
		retryDocumentIngestion({ ...env, DOCUMENT_INGESTION_WORKFLOW: workflow as unknown as Workflow }, failedDocumentId),
	).rejects.toThrow("The Workflows service is unavailable")

	expect(await readDocument()).toEqual([{ status: "failed", failureReason: "processing_error" }])
})
