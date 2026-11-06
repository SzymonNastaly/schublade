import { NonRetryableError } from "cloudflare:workflows"
import { and, asc, eq, exists, getTableColumns, inArray, sql } from "drizzle-orm"
import { connectDatabase } from "../database/client"
import {
	categories,
	documentTags,
	documents,
	extractedFields,
	householdMembers,
	senders,
	tags,
} from "../database/schema"
import { classifyDocument } from "../inference/document_classifier"
import { indexDocument } from "../search/document_indexing"
import { inspectPages, rasterizePage } from "../inference/page_rasterizer"
import { createMoondreamRecognizer } from "../inference/text_recognizer"
import { findStandardCategory } from "./document_classification"
import { assembleDocumentMarkdown, recognitionLimitViolation, selectPageTextSources } from "./document_text"
import { predecessorStatuses } from "./document_lifecycle"
import { contentObjectKey, parseSourceFile } from "./source_file"
import { resolveTaxonomyName } from "./taxonomy_resolution"
import { assessVerificationReason } from "./verification_assessment"
import type { WorkflowStep, WorkflowStepConfig } from "cloudflare:workers"
import type { InferInsertModel, SQL } from "drizzle-orm"
import type { SQLiteTable } from "drizzle-orm/sqlite-core"
import type { ArchiveDatabase } from "../database/client"
import type { SearchIndex } from "../search/document_indexing"
import type { MailContext } from "./classification_prompt"
import type { DocumentClassification } from "./document_classification"
import type { DocumentStatus } from "./document_lifecycle"
import type { PageTranscription, TextExtraction } from "./document_text"
import type { SourceFile } from "./source_file"

type IngestionEnvironment = Pick<
	Env,
	"DATABASE" | "DOCUMENT_STORAGE" | "AI_RUNTIME" | "AI_GATEWAY_IDENTIFIER" | "CLASSIFICATION_MODEL"
> & { SEARCH_INDEX: SearchIndex }

type IngestionStep = Pick<WorkflowStep, "do">

const RECOGNITION_DOTS_PER_INCH = 150

const inferenceStep: WorkflowStepConfig = {
	retries: { limit: 3, delay: "10 seconds", backoff: "exponential" },
	timeout: "5 minutes",
}
const recordStep: WorkflowStepConfig = {
	retries: { limit: 5, delay: "1 second", backoff: "exponential" },
	timeout: "1 minute",
}

export interface IngestionOutcome {
	documentId: string
	recognizedPageCount: number
	classificationModel: string
	classificationInputTokens: number
	classificationOutputTokens: number
}

/**
 * Moves a document along the status machine in document_lifecycle.ts. The update applies
 * only from a permitted predecessor, so a retried step that already moved the document
 * succeeds without a change, and an illegal move stops the workflow.
 */
export async function recordDocumentStatus(
	database: ArchiveDatabase,
	documentId: string,
	status: DocumentStatus,
): Promise<void> {
	const moved = await database
		.update(documents)
		.set({ status })
		.where(and(eq(documents.id, documentId), inArray(documents.status, predecessorStatuses(status))))
		.returning({ id: documents.id })
	if (moved.length > 0) return
	const [document] = await database
		.select({ status: documents.status })
		.from(documents)
		.where(eq(documents.id, documentId))
	if (document?.status === status) return
	throw new NonRetryableError(`Document ${documentId} cannot enter ${status} from ${document?.status ?? "no record"}`)
}

async function readOriginal(
	database: ArchiveDatabase,
	storage: R2Bucket,
	documentId: string,
): Promise<{ sourceFile: SourceFile; bytes: Uint8Array<ArrayBuffer> }> {
	const [document] = await database
		.select({ storageObjectKey: documents.storageObjectKey, mimeType: documents.mimeType })
		.from(documents)
		.where(eq(documents.id, documentId))
	if (!document) throw new NonRetryableError(`Document ${documentId} has no record`)
	const sourceFile = parseSourceFile(document.mimeType)
	if (!sourceFile) throw new NonRetryableError(`Document ${documentId} has the unsupported type ${document.mimeType}`)
	const object = await storage.get(document.storageObjectKey)
	if (!object) throw new NonRetryableError(`Document ${documentId} has no original at ${document.storageObjectKey}`)
	return { sourceFile, bytes: new Uint8Array(await object.arrayBuffer()) }
}

async function extractText(
	environment: IngestionEnvironment,
	sourceFile: SourceFile,
	bytes: Uint8Array<ArrayBuffer>,
): Promise<TextExtraction> {
	if (sourceFile.kind === "image") return { convertedMarkdown: "", pages: [{ kind: "recognition", pageIndex: 0 }] }
	const [conversion, pages] = await Promise.all([
		environment.AI_RUNTIME.toMarkdown(
			{ name: `original.${sourceFile.extension}`, blob: new Blob([bytes], { type: sourceFile.mediaType }) },
			{ gateway: { id: environment.AI_GATEWAY_IDENTIFIER }, conversionOptions: { pdf: { metadata: false } } },
		),
		inspectPages(bytes),
	])
	if (conversion.format === "error") throw new Error(`Markdown conversion failed: ${conversion.error}`)
	const pageTextSources = selectPageTextSources(pages, conversion.data)
	const limitViolation = recognitionLimitViolation(pageTextSources)
	if (limitViolation) throw new NonRetryableError(limitViolation)
	return { convertedMarkdown: conversion.data, pages: pageTextSources }
}

async function recognizePage(
	environment: IngestionEnvironment,
	original: { sourceFile: SourceFile; bytes: Uint8Array },
	pageIndex: number,
): Promise<PageTranscription> {
	const { sourceFile, bytes } = original
	const image =
		sourceFile.kind === "image"
			? { mediaType: sourceFile.mediaType, bytes }
			: {
					mediaType: "image/png" as const,
					bytes: (await rasterizePage(bytes, pageIndex, RECOGNITION_DOTS_PER_INCH)).pngBytes,
				}
	const recognizer = createMoondreamRecognizer(environment.AI_RUNTIME, environment.AI_GATEWAY_IDENTIFIER)
	return { pageIndex, text: await recognizer.transcribe(image) }
}

async function readTaxonomy(database: ArchiveDatabase) {
	const [senderRecords, categoryRecords, tagRecords, members] = await Promise.all([
		database
			.select({ id: senders.id, name: senders.name, normalizedName: senders.normalizedName })
			.from(senders)
			.orderBy(asc(senders.name)),
		database
			.select({
				id: categories.id,
				name: categories.name,
				normalizedName: categories.normalizedName,
				expectedFields: categories.expectedFields,
			})
			.from(categories)
			.orderBy(asc(categories.name)),
		database
			.select({ id: tags.id, name: tags.name, normalizedName: tags.normalizedName })
			.from(tags)
			.orderBy(asc(tags.name)),
		database
			.select({
				id: householdMembers.id,
				displayName: householdMembers.displayName,
				addresseeNames: householdMembers.addresseeNames,
			})
			.from(householdMembers)
			.orderBy(asc(householdMembers.displayName)),
	])
	return { senderRecords, categoryRecords, tagRecords, members }
}

/**
 * Writes the classification in one D1 transaction. Taxonomy names resolve against the rows
 * that exist now, not when the model ran, because a concurrent workflow may have created
 * the same sender in between. Foreign keys resolve by normalized name for the same reason.
 * Every write applies only while the document is classifying, so a document that left that
 * status keeps its tags and fields and adds no taxonomy rows. A record the classifier creates
 * awaits confirmation, except a standard category, which the prompt offers as established.
 */
async function archiveDocument(
	database: ArchiveDatabase,
	documentId: string,
	classification: DocumentClassification,
	pageCount: number,
): Promise<void> {
	const [document] = await database
		.select({ status: documents.status })
		.from(documents)
		.where(eq(documents.id, documentId))
	if (document?.status === "archived") return

	const { senderRecords, categoryRecords, tagRecords } = await readTaxonomy(database)
	const sender =
		classification.senderName === null ? null : resolveTaxonomyName(classification.senderName, senderRecords)
	const category =
		classification.categoryName === null ? null : resolveTaxonomyName(classification.categoryName, categoryRecords)
	const tagResolutions = classification.tagNames.map((name) => resolveTaxonomyName(name, tagRecords))
	const standardCategory = category?.kind === "new" ? findStandardCategory(category.normalizedName) : undefined
	const categoryExpectedFields =
		category?.kind === "existing" ? category.record.expectedFields : [...(standardCategory?.expectedFields ?? [])]

	const recordIdentifier = (table: typeof senders | typeof categories, normalizedName: string) =>
		sql<string>`(select ${table.id} from ${table} where ${table.normalizedName} = ${normalizedName})`
	const classifyingDocument = and(eq(documents.id, documentId), eq(documents.status, "classifying"))
	const documentIsClassifying = exists(database.select({ id: documents.id }).from(documents).where(classifyingDocument))
	// Selects the row from the document's own row, so an insert built on it writes nothing once
	// the document has left classifying. Insert-select assigns values by position, so the
	// selection follows the table's column order.
	const whileClassifying = <TTable extends SQLiteTable>(table: TTable, row: Required<InferInsertModel<TTable>>): SQL =>
		database
			.select(
				Object.fromEntries(
					Object.entries(getTableColumns(table)).map(([key, column]) => [
						key,
						sql`${sql.param(row[key as keyof typeof row], column)}`,
					]),
				),
			)
			.from(documents)
			.where(classifyingDocument)
			.getSQL()

	const archived = database
		.update(documents)
		.set({
			title: classification.title,
			documentDate: classification.documentDate,
			senderId: sender === null ? null : recordIdentifier(senders, sender.normalizedName),
			categoryId: category === null ? null : recordIdentifier(categories, category.normalizedName),
			personMemberId: classification.personMemberId,
			summary: classification.summary,
			pageCount,
			verificationReason: assessVerificationReason({
				nonArchival: classification.nonArchival,
				documentDate: classification.documentDate,
				categoryExpectedFields,
				fields: classification.extractedFields,
			}),
			status: "archived",
		})
		.where(classifyingDocument)

	await database.batch([
		database.delete(documentTags).where(and(eq(documentTags.documentId, documentId), documentIsClassifying)),
		database.delete(extractedFields).where(and(eq(extractedFields.documentId, documentId), documentIsClassifying)),
		...(sender?.kind === "new"
			? [
					database
						.insert(senders)
						.select(
							whileClassifying(senders, {
								id: crypto.randomUUID(),
								name: sender.name,
								normalizedName: sender.normalizedName,
								createdAt: new Date(),
								confirmedAt: null,
							}),
						)
						.onConflictDoNothing(),
				]
			: []),
		...(category?.kind === "new"
			? [
					database
						.insert(categories)
						.select(
							whileClassifying(categories, {
								id: crypto.randomUUID(),
								name: category.name,
								normalizedName: category.normalizedName,
								expectedFields: categoryExpectedFields,
								createdAt: new Date(),
								confirmedAt: standardCategory === undefined ? null : new Date(),
							}),
						)
						.onConflictDoNothing(),
				]
			: []),
		...tagResolutions.flatMap((resolution) =>
			resolution.kind === "new"
				? [
						database
							.insert(tags)
							.select(
								whileClassifying(tags, {
									id: crypto.randomUUID(),
									name: resolution.name,
									normalizedName: resolution.normalizedName,
									colorHex: null,
									createdAt: new Date(),
									confirmedAt: null,
								}),
							)
							.onConflictDoNothing(),
					]
				: [],
		),
		...(tagResolutions.length > 0
			? [
					database.insert(documentTags).select(
						database
							.select({ documentId: sql<string>`${documentId}`.as("document_id"), tagId: tags.id })
							.from(tags)
							.where(
								and(
									inArray(
										tags.normalizedName,
										tagResolutions.map((resolution) => resolution.normalizedName),
									),
									documentIsClassifying,
								),
							),
					),
				]
			: []),
		...classification.extractedFields.map((field) =>
			database.insert(extractedFields).select(
				whileClassifying(extractedFields, {
					id: crypto.randomUUID(),
					documentId,
					fieldKey: field.fieldKey,
					fieldType: field.fieldType,
					valueText: field.fieldType === "number" ? null : field.value,
					valueNumber: field.fieldType === "number" ? field.value : null,
					confidenceScore: field.confidence,
				}),
			),
		),
		archived,
	])
	const [archivedDocument] = await database
		.select({ status: documents.status })
		.from(documents)
		.where(eq(documents.id, documentId))
	if (archivedDocument?.status !== "archived") {
		throw new NonRetryableError(`Document ${documentId} left the classifying status before it was archived`)
	}
}

async function archiveIngestedDocument(
	step: IngestionStep,
	environment: IngestionEnvironment,
	database: ArchiveDatabase,
	documentId: string,
	mailContext: MailContext | undefined,
): Promise<IngestionOutcome> {
	try {
		const extraction = await step.do("extract text", inferenceStep, async () => {
			await recordDocumentStatus(database, documentId, "extracting")
			const { sourceFile, bytes } = await readOriginal(database, environment.DOCUMENT_STORAGE, documentId)
			return extractText(environment, sourceFile, bytes)
		})

		const transcriptions: Array<PageTranscription> = []
		const recognitionPages = extraction.pages.filter((page) => page.kind === "recognition")
		if (recognitionPages.length > 0) {
			await step.do("record status recognizing_text", recordStep, () =>
				recordDocumentStatus(database, documentId, "recognizing_text"),
			)
			for (const { pageIndex } of recognitionPages) {
				// Each page is its own step, so a failed page retries without repeating the others.
				const transcription = await step.do(`recognize page ${pageIndex + 1}`, inferenceStep, async () =>
					recognizePage(environment, await readOriginal(database, environment.DOCUMENT_STORAGE, documentId), pageIndex),
				)
				transcriptions.push(transcription)
			}
		}

		const markdown = assembleDocumentMarkdown(extraction, transcriptions)
		await step.do("store markdown", recordStep, async () => {
			await environment.DOCUMENT_STORAGE.put(contentObjectKey(documentId), markdown, {
				httpMetadata: { contentType: "text/markdown; charset=utf-8" },
			})
		})

		await step.do("record status classifying", recordStep, () =>
			recordDocumentStatus(database, documentId, "classifying"),
		)
		const result = await step.do("classify document", inferenceStep, async () => {
			const { senderRecords, categoryRecords, tagRecords, members } = await readTaxonomy(database)
			return classifyDocument(
				environment.AI_RUNTIME,
				environment.AI_GATEWAY_IDENTIFIER,
				environment.CLASSIFICATION_MODEL,
				{
					markdown,
					mail: mailContext,
					senderNames: senderRecords.map((record) => record.name),
					categoryNames: categoryRecords.map((record) => record.name),
					tagNames: tagRecords.map((record) => record.name),
					members,
				},
			)
		})

		await step.do("archive document", recordStep, () =>
			archiveDocument(database, documentId, result.classification, extraction.pages.length),
		)
		return {
			documentId,
			recognizedPageCount: transcriptions.length,
			classificationModel: environment.CLASSIFICATION_MODEL,
			classificationInputTokens: result.inputTokens,
			classificationOutputTokens: result.outputTokens,
		}
	} catch (error) {
		await step.do("record status failed", recordStep, () => recordDocumentStatus(database, documentId, "failed"))
		throw error
	}
}

/**
 * Archives the document, then indexes it in AI Search. A failed index step leaves the document
 * archived, and indexMissingDocuments uploads it later.
 */
export async function ingestDocument(
	step: IngestionStep,
	environment: IngestionEnvironment,
	documentId: string,
	mailContext?: MailContext,
): Promise<IngestionOutcome> {
	const database = connectDatabase(environment.DATABASE)
	const outcome = await archiveIngestedDocument(step, environment, database, documentId, mailContext)
	await step.do("index document", recordStep, () =>
		indexDocument(database, environment.DOCUMENT_STORAGE, environment.SEARCH_INDEX, documentId),
	)
	return outcome
}
