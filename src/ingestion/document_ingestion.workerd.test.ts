import { applyD1Migrations, env, reset } from "cloudflare:test"
import { eq } from "drizzle-orm"
import { expect, inject, test } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import expectedExtraction from "../../test_fixtures/documents/expected_extraction.json"
import recording from "../../test_fixtures/inference_recordings/electricity_invoice_scanned.json"
import { queryDocumentListing } from "../archive/document_listing"
import { connectDatabase } from "../database/client"
import { categories, documents, extractedFields, senders, tags } from "../database/schema"
import { ingestDocument } from "./document_ingestion"
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

async function storeScannedInvoice(documentId: string) {
	await reset()
	searchIndexUploads.length = 0
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	const storageObjectKey = `documents/${documentId}/original.pdf`
	await env.DOCUMENT_STORAGE.put(storageObjectKey, scannedInvoice)
	await database.insert(documents).values({
		id: documentId,
		storageObjectKey,
		mimeType: "application/pdf",
		byteSize: scannedInvoice.byteLength,
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
			personName: null,
			summary:
				"This is an annual electricity consumption statement from Stadtwerke Talbrück for the joint supply address Am Lindenhang 7, covering 1 September 2025 to 31 August 2026. It records a consumption of 2,691 kWh and requires a Nachzahlung of €72.09 by 6 October 2026.",
			mimeType: "application/pdf",
			pageCount: 1,
			verificationReason: "new_taxonomy_record",
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
