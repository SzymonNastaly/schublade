import { createHash } from "node:crypto"
import { mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import {
	blankSheet,
	createRandomSource,
	rotateClockwise,
	simulateFlatbedScan,
	simulatePagePhotograph,
	simulateReceiptPhotograph,
} from "./test_document_generation/capture_simulation.ts"
import { corpusCases } from "./test_document_generation/collection_corpus.ts"
import {
	composeImagePdf,
	encodeJpeg,
	extractPageTexts,
	loadPdfium,
	rasterizePages,
	renderSourcePdf,
	verifySourcePdf,
} from "./test_document_generation/document_rendering.ts"
import type { GrayscaleRaster, RandomSource } from "./test_document_generation/capture_simulation.ts"
import type { CollectionOutcome, CorpusSource, FileCapture } from "./test_document_generation/collection_corpus.ts"
import type { DocumentSpecification, PageSize } from "./test_document_generation/document_layout.ts"
import type { ImagePage, PdfInformation } from "./test_document_generation/document_rendering.ts"

const corpusDirectory = fileURLToPath(new URL("../test_fixtures/collection_corpus/", import.meta.url))
const manifestPath = fileURLToPath(new URL("../test_fixtures/expected_collection.json", import.meta.url))
const latestPermittedDocumentDate = "2026-11-17"
const creator = "scripts/generate_collection_corpus.ts"
const imageCreationDate = new Date("2026-11-16T18:00:00Z")

type Rendition = "digital" | "digital_rewritten" | "flatbed_scan" | "photograph" | "not_a_document"

const renditionOfCapture = {
	digital: "digital",
	digital_rewritten: "digital_rewritten",
	flatbed_scan: "flatbed_scan",
	page_photograph: "photograph",
	receipt_photograph: "photograph",
	partial_download: "not_a_document",
	text_content: "not_a_document",
} as const satisfies Record<FileCapture["kind"], Rendition>

// The archive shows a text layer over a scan over a photograph, and the sharper of two scans.
const displayPreference = (capture: FileCapture): number => {
	const rank = { digital: 3, digital_rewritten: 3, flatbed_scan: 2, photograph: 1, not_a_document: 0 }[
		renditionOfCapture[capture.kind]
	]
	return capture.kind === "flatbed_scan" ? rank * 1000 + capture.dotsPerInch : rank * 1000
}

const isHouseholdDocument = (source: CorpusSource): source is DocumentSpecification => "documentDate" in source
const issueDateOf = (source: CorpusSource): string =>
	isHouseholdDocument(source) ? String(source.documentDate.value) : source.publicationDate
const sourceLabel = (source: CorpusSource): string =>
	isHouseholdDocument(source) ? `${source.sender} ${issueDateOf(source)}` : `publication ${issueDateOf(source)}`

function sourcesOf(capture: FileCapture): Array<CorpusSource> {
	switch (capture.kind) {
		case "digital":
		case "digital_rewritten":
		case "page_photograph":
		case "receipt_photograph":
			return [capture.source]
		case "flatbed_scan":
			return capture.sheets.flatMap((sheet) => (sheet.kind === "page" ? [sheet.source] : []))
		case "partial_download":
		case "text_content":
			return []
	}
}

const pdfium = await loadPdfium()
const renderedSources = new Map<CorpusSource, Buffer>()

const characterCountsPerPage = (bytes: Uint8Array): Array<number> =>
	extractPageTexts(pdfium, bytes).map((text) => text.replace(/\s/g, "").length)

async function renderSource(source: CorpusSource): Promise<Buffer> {
	const cached = renderedSources.get(source)
	if (cached) return cached
	const information: PdfInformation = { creator, creationDate: new Date(`${issueDateOf(source)}T09:30:00Z`) }
	const bytes = await renderSourcePdf(source, information)
	const label = sourceLabel(source)
	const characterCounts = characterCountsPerPage(bytes)
	if (characterCounts.length !== source.pageCount || characterCounts.some((count) => count === 0))
		throw new Error(`${label}: characters per page ${characterCounts.join(", ")}, expected ${source.pageCount} pages`)
	if (isHouseholdDocument(source)) verifySourcePdf(label, source, extractPageTexts(pdfium, bytes))
	renderedSources.set(source, bytes)
	return bytes
}

async function rasterizeSourcePage(source: CorpusSource, pageIndex: number, dotsPerInch: number) {
	const page = rasterizePages(pdfium, await renderSource(source), dotsPerInch)[pageIndex]
	if (!page) throw new Error(`${sourceLabel(source)} has no page ${pageIndex + 1}`)
	return page
}

async function photographSinglePage(source: CorpusSource, dotsPerInch: number): Promise<GrayscaleRaster> {
	if (source.pageCount !== 1) throw new Error(`${sourceLabel(source)}: a photograph holds one page`)
	return rasterizeSourcePage(source, 0, dotsPerInch)
}

async function scanSheets(capture: Extract<FileCapture, { kind: "flatbed_scan" }>, random: RandomSource) {
	const pages: Array<ImagePage> = []
	for (const sheet of capture.sheets) {
		const pageSize: PageSize = sheet.kind === "page" ? sheet.source.pageSize : sheet.pageSize
		const raster =
			sheet.kind === "page"
				? await rasterizeSourcePage(sheet.source, sheet.pageIndex, capture.dotsPerInch)
				: blankSheet(
						Math.round((pageSize[0] * capture.dotsPerInch) / 72),
						Math.round((pageSize[1] * capture.dotsPerInch) / 72),
					)
		const scanned = rotateClockwise(simulateFlatbedScan(raster, random), capture.quarterTurns)
		pages.push({
			jpeg: encodeJpeg(scanned, 68),
			size: capture.quarterTurns % 2 === 1 ? [pageSize[1], pageSize[0]] : pageSize,
		})
	}
	const bytes = await composeImagePdf(pages, { creator, creationDate: imageCreationDate })
	const characterCounts = characterCountsPerPage(bytes)
	if (characterCounts.length !== capture.sheets.length || characterCounts.some((count) => count > 0))
		throw new Error(`a scan has characters per page ${characterCounts.join(", ")} for ${capture.sheets.length} sheets`)
	return bytes
}

function verifyJpeg(bytes: Buffer): Buffer {
	if (bytes[0] !== 0xff || bytes[1] !== 0xd8) throw new Error("a photograph is not a JPEG stream")
	return bytes
}

async function produceFile(capture: FileCapture, random: RandomSource): Promise<Buffer> {
	switch (capture.kind) {
		case "digital":
			return renderSource(capture.source)
		case "digital_rewritten": {
			const original = await renderSource(capture.source)
			const rewritten = await renderSourcePdf(capture.source, {
				creator,
				creationDate: new Date(capture.creationDate),
			})
			const originalText = JSON.stringify(extractPageTexts(pdfium, original))
			if (rewritten.equals(original) || JSON.stringify(extractPageTexts(pdfium, rewritten)) !== originalText)
				throw new Error(`${sourceLabel(capture.source)}: a rewritten PDF must keep the text and change the bytes`)
			return rewritten
		}
		case "flatbed_scan":
			return scanSheets(capture, random)
		case "page_photograph":
			return verifyJpeg(encodeJpeg(simulatePagePhotograph(await photographSinglePage(capture.source, 150), random), 80))
		case "receipt_photograph":
			return verifyJpeg(
				encodeJpeg(simulateReceiptPhotograph(await photographSinglePage(capture.source, 190), random), 80),
			)
		case "partial_download": {
			const complete = await produceFile(capture.completeFile, random)
			return complete.subarray(0, Math.floor(complete.length * capture.retainedFraction))
		}
		case "text_content":
			return Buffer.from(capture.text, "utf8")
	}
}

const sha256 = (bytes: Uint8Array): string => createHash("sha256").update(bytes).digest("hex")

interface ManifestFile {
	path: string
	sha256: string
	byte_size: number
	rendition: Rendition
	case_key: string
	outcome: CollectionOutcome
}

const startTime = performance.now()
const writtenFiles: Array<{ path: string; bytes: Buffer; capture: FileCapture }> = []
const manifestFiles: Array<ManifestFile> = []
for (const corpusCase of corpusCases) {
	for (const file of corpusCase.files) {
		const bytes = await produceFile(file.capture, createRandomSource(file.path))
		writtenFiles.push({ path: file.path, bytes, capture: file.capture })
		manifestFiles.push({
			path: file.path,
			sha256: sha256(bytes),
			byte_size: bytes.length,
			rendition: renditionOfCapture[file.capture.kind],
			case_key: corpusCase.key,
			outcome: file.outcome,
		})
		console.log(`${file.path.padEnd(84)} ${(bytes.length / 1024).toFixed(0).padStart(5)} KiB`)
	}
}

const corpusDocuments = corpusCases.flatMap((corpusCase) => corpusCase.documents)
const manifest = {
	documents: corpusDocuments.map((document) => ({
		document_key: document.key,
		displayed_path: document.displayedPath,
		related_documents: (document.relatedDocuments ?? []).map(({ relation, documentKey }) => ({
			relation,
			document_key: documentKey,
		})),
		sender: document.specification.sender,
		document_date: document.specification.documentDate.value,
		fields: document.specification.fields,
	})),
	files: manifestFiles,
}

function verifyManifest(): void {
	const failures: Array<string> = []
	const duplicates = (values: ReadonlyArray<string>) => values.filter((value, index) => values.indexOf(value) !== index)
	for (const path of duplicates(manifestFiles.map((file) => file.path))) failures.push(`path ${path} appears twice`)
	for (const key of duplicates(corpusDocuments.map((document) => document.key)))
		failures.push(`document key ${key} appears twice`)
	const documentsByKey = new Map(corpusDocuments.map((document) => [document.key, document]))
	const capturesByPath = new Map(writtenFiles.map((file) => [file.path, file.capture]))
	for (const file of manifestFiles) {
		if (file.outcome.kind !== "archived") continue
		const document = documentsByKey.get(file.outcome.document_key)
		if (!document) failures.push(`${file.path} names the unknown document ${file.outcome.document_key}`)
		else if (!sourcesOf(capturesByPath.get(file.path)!).includes(document.specification))
			failures.push(`${file.path} does not show the document ${document.key}`)
	}
	for (const document of corpusDocuments) {
		const archivedPaths = manifestFiles
			.filter((file) => file.outcome.kind === "archived" && file.outcome.document_key === document.key)
			.map((file) => file.path)
		if (archivedPaths.length === 0) failures.push(`${document.key} has no archived file`)
		if (!archivedPaths.includes(document.displayedPath))
			failures.push(`${document.key} displays ${document.displayedPath}, which is not one of its archived files`)
		else {
			const preference = (path: string) => displayPreference(capturesByPath.get(path)!)
			const preferred = archivedPaths.find((path) => preference(path) > preference(document.displayedPath))
			if (preferred)
				failures.push(`${document.key} displays ${document.displayedPath} although ${preferred} ranks higher`)
		}
		for (const related of document.relatedDocuments ?? []) {
			if (!documentsByKey.has(related.documentKey))
				failures.push(`${document.key} ${related.relation} the unknown document ${related.documentKey}`)
		}
		if (String(document.specification.documentDate.value) > latestPermittedDocumentDate)
			failures.push(`${document.key} is dated after ${latestPermittedDocumentDate}`)
	}
	if (failures.length > 0) throw new Error(`The collection manifest is inconsistent:\n${failures.join("\n")}`)
}
verifyManifest()

await rm(corpusDirectory, { recursive: true, force: true })
await rm(manifestPath, { force: true })
for (const { path, bytes } of writtenFiles) {
	const target = join(corpusDirectory, ...path.split("/"))
	await mkdir(dirname(target), { recursive: true })
	await writeFile(target, bytes)
}
await writeFile(manifestPath, `${JSON.stringify(manifest, null, "\t")}\n`)

for (const file of manifestFiles) {
	const bytes = await readFile(join(corpusDirectory, ...file.path.split("/")))
	if (bytes.length !== file.byte_size || sha256(bytes) !== file.sha256)
		throw new Error(`${file.path} on disk differs from its manifest entry`)
}

const totalBytes = writtenFiles.reduce((total, file) => total + file.bytes.length, 0)
console.log(
	`${writtenFiles.length} files of ${corpusDocuments.length} documents, ${(totalBytes / 1024 / 1024).toFixed(2)} MiB in ${corpusDirectory}, manifest at ${manifestPath}, ${((performance.now() - startTime) / 1000).toFixed(1)} s`,
)
