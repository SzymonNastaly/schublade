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

const recordedEnvironment = {
	...env,
	AI_RUNTIME: recordedRuntime as unknown as Ai,
	CLASSIFICATION_MODEL: "@cf/google/gemma-4-26b-a4b-it",
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

test("ingestDocument recognizes, classifies, and archives a scanned invoice one step per unit", async () => {
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
	])
	expect(outcome).toEqual({
		documentId,
		recognizedPageCount: 1,
		classificationModel: "@cf/google/gemma-4-26b-a4b-it",
		classificationInputTokens: 2347,
		classificationOutputTokens: 2172,
	})
	const expected = expectedExtraction.documents.find(
		(document) => document.file_name === "electricity_invoice_scanned.pdf",
	)?.fields
	expect(await queryDocumentListing(database)).toEqual([
		{
			id: documentId,
			status: "archived",
			title: "Stadtwerke Talbrück Electricity Annual Statement 2025-2026",
			documentDate: "2026-09-22",
			senderName: "Stadtwerke Talbrück GmbH",
			categoryName: "Invoice",
			personName: null,
			summary:
				"This is an annual electricity consumption statement from Stadtwerke Talbrück GmbH. It records the electricity usage from September 2025 to August 2026 and requires a back payment of 72.09 EUR.",
			mimeType: "application/pdf",
			pageCount: 1,
			verificationReason: "new_taxonomy_record",
			fields: [
				{ fieldKey: "amount", value: expected?.amount?.value, confidence: 1 },
				{ fieldKey: "currency", value: expected?.currency?.value, confidence: 1 },
				{ fieldKey: "due_date", value: expected?.due_date?.value, confidence: 1 },
				{ fieldKey: "iban", value: expected?.iban?.value, confidence: 1 },
				{ fieldKey: "invoice_number", value: expected?.invoice_number?.value, confidence: 1 },
			],
		},
	])
	const markdown = await (await env.DOCUMENT_STORAGE.get(contentObjectKey(documentId)))?.text()
	expect(markdown?.split("\n").filter((line) => line.includes("Nachzahlungsbetrag"))).toEqual([
		"Bitte überweisen Sie den Nachzahlungsbetrag von 72,09 € bis zum 06.10.2026 unter Angabe der Rechnungsnummer JA-2026-0381547 das folgende Konto:",
	])
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
