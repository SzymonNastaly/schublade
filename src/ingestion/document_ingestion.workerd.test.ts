import { applyD1Migrations, env, reset } from "cloudflare:test"
import { eq } from "drizzle-orm"
import { expect, inject, test, vi } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import digitalInvoice from "../../test_fixtures/documents/telecommunication_invoice_digital.pdf"
import expectedExtraction from "../../test_fixtures/documents/expected_extraction.json"
import recording from "../../test_fixtures/inference_recordings/electricity_invoice_scanned.json"
import { connectToArchiveChanges } from "../archive/archive_changes"
import { queryDocumentListing } from "../archive/document_listing"
import { connectDatabase } from "../database/client"
import { categories, documents, extractedFields, senders, tags } from "../database/schema"
import { ingestDocument, retryDocumentIngestion, startWaitingMailRendering } from "./document_ingestion"
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

const browserRenderings: Array<{ action: string; html: string; scripts: boolean }> = []

const recordedEnvironment = {
	...env,
	AI_RUNTIME: recordedRuntime as unknown as Ai,
	CLASSIFICATION_MODEL: "@cf/deepseek-ai/deepseek-v4.1-flash-1017",
	SEARCH_INDEX: recordingSearchIndex,
	// Browser Run bills per request, so the test answers with a stored PDF.
	BROWSER_RENDERER: {
		quickAction: (action: string, options: { html: string; setJavaScriptEnabled: boolean }) => {
			browserRenderings.push({ action, html: options.html, scripts: options.setJavaScriptEnabled })
			return Promise.resolve(new Response(scannedInvoice, { headers: { "Content-Type": "application/pdf" } }))
		},
	} as unknown as BrowserRun,
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
		"render email",
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

test("a browser open during ingestion hears each status the workflow records", async () => {
	const documentId = "2a6e4d0c-7f93-4b5a-8c14-5d3f9e0b6a32"
	await storeScannedInvoice(documentId)
	const { webSocket } = await connectToArchiveChanges(
		env,
		new Request("https://archive.test/api/archive_changes", { headers: { Upgrade: "websocket" } }),
	)
	webSocket?.accept()
	let announcements = 0
	webSocket?.addEventListener("message", () => {
		announcements += 1
	})

	await ingestDocument(createRecordingStep().step, recordedEnvironment, documentId)

	// extracting, recognizing_text, classifying, and archived
	await vi.waitFor(() => expect(announcements).toBe(4))
	webSocket?.close()
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
			stepNames: ["render email", "extract text", "record status failed"],
		},
		damagedFile: {
			status: "failed",
			failureReason: "unreadable_file",
			message: "PDFium could not open the document, error code 3",
			stepNames: ["render email", "extract text", "record status failed"],
		},
		serviceError: {
			status: "failed",
			failureReason: "processing_error",
			message: "The conversion service is unavailable",
			stepNames: ["render email", "extract text", "record status failed"],
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
		database
			.select({
				status: documents.status,
				failureReason: documents.failureReason,
				quarterTurns: documents.recognitionQuarterTurns,
			})
			.from(documents)
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
		documents: [{ status: "processing", failureReason: null, quarterTurns: 0 }],
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

	expect(await readDocument()).toEqual([{ status: "failed", failureReason: "processing_error", quarterTurns: 0 }])
})

const receiptMessage = [
	"From: Mira Becker <mira@example.com>",
	"Subject: Fwd: Your receipt from Paperlark",
	"Message-ID: <receipt@example.com>",
	"MIME-Version: 1.0",
	"Content-Type: text/html; charset=utf-8",
	"",
	'<meta http-equiv="refresh" content="0;url=https://elsewhere.example/"><script>steal()</script>',
	'<iframe src="https://elsewhere.example/"></iframe><p>Total 12,99 EUR</p>',
	"",
].join("\r\n")

async function storeMessage(documentId: string, message: string) {
	await reset()
	searchIndexUploads.length = 0
	browserRenderings.length = 0
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const storageObjectKey = `documents/${documentId}/original.eml`
	await env.DOCUMENT_STORAGE.put(storageObjectKey, message)
	const database = connectDatabase(env.DATABASE)
	await database.insert(documents).values({
		id: documentId,
		storageObjectKey,
		mimeType: "message/rfc822",
		byteSize: message.length,
		status: "awaiting_rendering",
	})
	return database
}

test("ingestDocument prints a stored email to a PDF, archives that, and keeps the message", async () => {
	const documentId = "f1000000-0000-4000-8000-000000000001"
	const database = await storeMessage(documentId, receiptMessage)
	const { stepNames, step } = createRecordingStep()

	await ingestDocument(step, recordedEnvironment, documentId)

	const [document] = await database
		.select({ status: documents.status, mimeType: documents.mimeType, storageObjectKey: documents.storageObjectKey })
		.from(documents)
		.where(eq(documents.id, documentId))
	const objects = (await env.DOCUMENT_STORAGE.list({ prefix: `documents/${documentId}/` })).objects.map(
		({ key }) => key,
	)
	expect({
		firstSteps: stepNames.slice(0, 2),
		document,
		objects,
		renderings: browserRenderings.map(({ action, scripts }) => ({ action, scripts })),
		printedSubject: browserRenderings[0]?.html.includes("Fwd: Your receipt from Paperlark"),
		printedBody: browserRenderings[0]?.html.includes("<p>Total 12,99 EUR</p>"),
		activeMarkup: /elsewhere\.example|<script/.test(browserRenderings[0]?.html ?? ""),
	}).toEqual({
		firstSteps: ["render email", "extract text"],
		document: {
			status: "archived",
			mimeType: "application/pdf",
			storageObjectKey: `documents/${documentId}/original.pdf`,
		},
		objects: [
			`documents/${documentId}/content.md`,
			`documents/${documentId}/original.eml`,
			`documents/${documentId}/original.pdf`,
		],
		renderings: [{ action: "pdf", scripts: false }],
		printedSubject: true,
		printedBody: true,
		activeMarkup: false,
	})
})

test("ingestDocument reads a printed email from its text layer, without the conversion, and gives the classifier the body once", async () => {
	const documentId = "f1000000-0000-4000-8000-000000000005"
	await storeMessage(documentId, receiptMessage)
	const classificationRequests: Array<string> = []
	const { step } = createRecordingStep()

	await ingestDocument(
		step,
		{
			...recordedEnvironment,
			AI_RUNTIME: {
				toMarkdown: () => Promise.reject(new Error("A printed email needs no conversion")),
				run: (_model: string, inputs: unknown) => {
					classificationRequests.push(JSON.stringify(inputs))
					return Promise.resolve(recording.classificationResponse)
				},
			} as unknown as Ai,
			BROWSER_RENDERER: {
				quickAction: () =>
					Promise.resolve(new Response(digitalInvoice, { headers: { "Content-Type": "application/pdf" } })),
			} as unknown as BrowserRun,
		},
		documentId,
	)

	const content = await (await env.DOCUMENT_STORAGE.get(contentObjectKey(documentId)))?.text()
	expect({
		invoiceNumberInText: content?.includes("NK-2026-1048-3391"),
		emptyEmailBody: classificationRequests[0]?.includes("<email>\\n\\n</email>"),
	}).toEqual({ invoiceNumberInText: true, emptyEmailBody: true })
})

function recognitionEventStream(answer: string, finishReason: string) {
	return new Response(`data: ${JSON.stringify({ chunk: { answer, finish_reason: finishReason } })}\n\ndata: [DONE]\n\n`)
		.body
}

function pngDimensions(dataUri: string) {
	const bytes = Uint8Array.from(atob(dataUri.split(",")[1] ?? ""), (character) => character.charCodeAt(0))
	const view = new DataView(bytes.buffer)
	return { width: view.getUint32(16), height: view.getUint32(20) }
}

test("a page that reaches the token limit fails its document, and a retry reads the page a quarter turn further", async () => {
	const documentId = "a1000000-0000-4000-8000-000000000001"
	const database = await storeScannedInvoice(documentId)
	const recognitionRequests: Array<{ image: string; tokenLimit: number; skipsCache: boolean }> = []
	const runtimeFinishingWith = (finishReason: string) =>
		({
			toMarkdown: recordedRuntime.toMarkdown,
			run: (
				model: string,
				inputs: { image: string; max_tokens: number },
				options: { gateway: { skipCache: boolean } },
			) => {
				if (model !== "@cf/moondream/moondream3.1-9B-A2B") return Promise.resolve(recording.classificationResponse)
				recognitionRequests.push({
					image: inputs.image,
					tokenLimit: inputs.max_tokens,
					skipsCache: options.gateway.skipCache,
				})
				return Promise.resolve(recognitionEventStream("Seite Seite Seite", finishReason))
			},
		}) as unknown as Ai
	const { stepNames, step } = createRecordingStep()

	const message = await ingestDocument(
		step,
		{ ...recordedEnvironment, AI_RUNTIME: runtimeFinishingWith("length") },
		documentId,
	).catch((error: Error) => error.message)
	const [failedDocument] = await database
		.select({ status: documents.status, failureReason: documents.failureReason })
		.from(documents)
	await retryDocumentIngestion(
		{ ...env, DOCUMENT_INGESTION_WORKFLOW: { create: () => Promise.resolve() } as unknown as Workflow },
		documentId,
	)
	await ingestDocument(
		createRecordingStep().step,
		{ ...recordedEnvironment, AI_RUNTIME: runtimeFinishingWith("stop") },
		documentId,
	)

	expect({
		message,
		failedDocument,
		stepNames,
		pages: recognitionRequests.map(({ image }) => pngDimensions(image)),
		requests: recognitionRequests.map(({ tokenLimit, skipsCache }) => ({ tokenLimit, skipsCache })),
	}).toEqual({
		message: "Page 1 did not finish within the token limit",
		failedDocument: { status: "failed", failureReason: "unreadable_page" },
		stepNames: [
			"render email",
			"extract text",
			"record status recognizing_text",
			"recognize page 1",
			"record status failed",
		],
		pages: [
			{ width: 1240, height: 1754 },
			{ width: 1754, height: 1240 },
		],
		requests: [
			{ tokenLimit: 2048, skipsCache: true },
			{ tokenLimit: 2048, skipsCache: true },
		],
	})
})

test("ingestDocument sends an uploaded photograph through the image transformer before text recognition", async () => {
	const documentId = "a1000000-0000-4000-8000-000000000002"
	const database = await storeScannedInvoice(documentId, new Uint8Array([0xff, 0xd8, 0xff, 0x01]))
	await database.update(documents).set({ mimeType: "image/jpeg", recognitionQuarterTurns: 2 })
	const transformations: Array<unknown> = []
	let inputBytes: Promise<ArrayBuffer> = Promise.resolve(new ArrayBuffer(0))
	const imageTransformer = {
		input(stream: ReadableStream<Uint8Array>) {
			inputBytes = new Response(stream).arrayBuffer()
			const transformer = {
				transform(options: unknown) {
					transformations.push(options)
					return transformer
				},
				output(options: unknown) {
					transformations.push(options)
					return Promise.resolve({ response: () => new Response(new Uint8Array([1, 2, 3])) })
				},
			}
			return transformer
		},
	}
	const recognizedImages: Array<string> = []
	const { step } = createRecordingStep()

	await ingestDocument(
		step,
		{
			...recordedEnvironment,
			IMAGE_TRANSFORMER: imageTransformer as unknown as ImagesBinding,
			AI_RUNTIME: {
				run: (model: string, inputs: { image: string }) => {
					if (model !== "@cf/moondream/moondream3.1-9B-A2B") return Promise.resolve(recording.classificationResponse)
					recognizedImages.push(inputs.image)
					return Promise.resolve(recognitionEventStream("Stadtwerke Talbrück", "stop"))
				},
			} as unknown as Ai,
		},
		documentId,
	)

	expect({ input: [...new Uint8Array(await inputBytes)], transformations, recognizedImages }).toEqual({
		input: [0xff, 0xd8, 0xff, 0x01],
		transformations: [
			{ width: 1600, height: 1600, fit: "scale-down", rotate: 180 },
			{ format: "image/jpeg", quality: 90, background: "#FFFFFF" },
		],
		recognizedImages: ["data:image/jpeg;base64,AQID"],
	})
})

test("ingestDocument records an email without a body as unreadable and renders nothing", async () => {
	const documentId = "f1000000-0000-4000-8000-000000000002"
	const database = await storeMessage(documentId, "From: mira@example.com\r\nSubject: Empty\r\n\r\n")
	const { step } = createRecordingStep()

	await expect(ingestDocument(step, recordedEnvironment, documentId)).rejects.toThrow(
		"The message has no body to render",
	)

	const [document] = await database
		.select({ status: documents.status, failureReason: documents.failureReason })
		.from(documents)
		.where(eq(documents.id, documentId))
	expect({ document, renderings: browserRenderings.length }).toEqual({
		document: { status: "failed", failureReason: "unreadable_file" },
		renderings: 0,
	})
})

test("retryDocumentIngestion refuses a message that is still awaiting rendering", async () => {
	const documentId = "f1000000-0000-4000-8000-000000000004"
	await storeMessage(documentId, receiptMessage)

	await expect(retryDocumentIngestion(env, documentId)).rejects.toThrow(
		`Document ${documentId} has not failed, so it cannot be retried`,
	)
})

test("startWaitingMailRendering starts each waiting message under its own identifier, and one that cannot start stays waiting", async () => {
	const documentId = "f1000000-0000-4000-8000-000000000003"
	const database = await storeMessage(documentId, receiptMessage)
	const started: Array<unknown> = []
	const accepting = { create: (options: unknown) => Promise.resolve(started.push(options)) }
	const refusing = { create: () => Promise.reject(new Error("instance already exists")) }
	const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined)

	await startWaitingMailRendering({ ...env, DOCUMENT_INGESTION_WORKFLOW: accepting as unknown as Workflow })
	await startWaitingMailRendering({ ...env, DOCUMENT_INGESTION_WORKFLOW: refusing as unknown as Workflow })

	const [document] = await database.select({ status: documents.status }).from(documents)
	expect({ started, status: document?.status, warnings: warning.mock.calls.length }).toEqual({
		started: [{ id: documentId, params: { documentId } }],
		status: "awaiting_rendering",
		warnings: 1,
	})
	warning.mockRestore()
})
