import { mkdir, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import {
	createRandomSource,
	simulateFlatbedScan,
	simulateReceiptPhotograph,
} from "./test_document_generation/capture_simulation.ts"
import { documentCatalog } from "./test_document_generation/document_catalog.ts"
import { householdMembers } from "./test_document_generation/document_layout.ts"
import {
	composeImagePdf,
	encodeJpeg,
	extractPageTexts,
	loadPdfium,
	rasterizePages,
	renderSourcePdf,
	verifySourcePdf,
} from "./test_document_generation/document_rendering.ts"
import type { CaptureMethod, DocumentSpecification } from "./test_document_generation/document_layout.ts"
import type { PdfInformation, Pdfium } from "./test_document_generation/document_rendering.ts"

const outputDirectory = fileURLToPath(new URL("../test_fixtures/documents/", import.meta.url))
const scanResolutionDotsPerInch = 150
const photographResolutionDotsPerInch = 190

const captureFormats = {
	digital: { extension: "pdf", mediaType: "application/pdf", hasTextLayer: true },
	scanned: { extension: "pdf", mediaType: "application/pdf", hasTextLayer: false },
	photographed: { extension: "jpg", mediaType: "image/jpeg", hasTextLayer: false },
} as const satisfies Record<CaptureMethod, { extension: string; mediaType: string; hasTextLayer: boolean }>

const pdfInformation = (specification: DocumentSpecification): PdfInformation => ({
	creator: "scripts/generate_test_documents.ts",
	creationDate: new Date(`${specification.documentDate.value}T09:30:00Z`),
})

async function captureDocument(
	pdfium: Pdfium,
	specification: DocumentSpecification,
	sourcePdf: Buffer,
): Promise<Buffer> {
	const random = createRandomSource(specification.fileStem)
	switch (specification.captureMethod) {
		case "digital":
			return sourcePdf
		case "scanned": {
			const pages = rasterizePages(pdfium, sourcePdf, scanResolutionDotsPerInch).map((page) => ({
				jpeg: encodeJpeg(simulateFlatbedScan(page, random), 68),
				size: specification.pageSize,
			}))
			return composeImagePdf(pages, pdfInformation(specification))
		}
		case "photographed": {
			const [receipt] = rasterizePages(pdfium, sourcePdf, photographResolutionDotsPerInch)
			if (!receipt) throw new Error(`${specification.fileStem} rendered no page to photograph`)
			return encodeJpeg(simulateReceiptPhotograph(receipt, random), 80)
		}
	}
}

function verifyCapturedDocument(pdfium: Pdfium, specification: DocumentSpecification, bytes: Buffer): void {
	const format = captureFormats[specification.captureMethod]
	if (format.mediaType === "image/jpeg") {
		if (bytes[0] !== 0xff || bytes[1] !== 0xd8)
			throw new Error(`${specification.fileStem}: output is not a JPEG stream`)
		return
	}
	const characterCounts = extractPageTexts(pdfium, bytes).map((text) => text.replace(/\s/g, "").length)
	if (characterCounts.length !== specification.pageCount)
		throw new Error(`${specification.fileStem}: output has ${characterCounts.length} pages`)
	const textLayerMatches = format.hasTextLayer
		? characterCounts.every((count) => count > 0)
		: characterCounts.every((count) => count === 0)
	if (!textLayerMatches)
		throw new Error(
			`${specification.fileStem}: text characters per page ${characterCounts.join(", ")} contradict has_text_layer ${format.hasTextLayer}`,
		)
}

function describeExpectedExtraction(specification: DocumentSpecification) {
	const format = captureFormats[specification.captureMethod]
	return {
		file_name: `${specification.fileStem}.${format.extension}`,
		media_type: format.mediaType,
		capture_method: specification.captureMethod,
		has_text_layer: format.hasTextLayer,
		page_count: specification.pageCount,
		language: specification.language,
		category: specification.category,
		sender: specification.sender,
		person: specification.person,
		document_date: specification.documentDate.value,
		title_hint: specification.titleHint,
		fields: specification.fields,
	}
}

const pdfium = await loadPdfium()
const generatedFiles: Array<{ fileName: string; bytes: Buffer }> = []
const expectations = []
for (const specification of documentCatalog) {
	const sourcePdf = await renderSourcePdf(specification, pdfInformation(specification))
	verifySourcePdf(specification.fileStem, specification, extractPageTexts(pdfium, sourcePdf))
	const captured = await captureDocument(pdfium, specification, sourcePdf)
	verifyCapturedDocument(pdfium, specification, captured)
	const expectation = describeExpectedExtraction(specification)
	generatedFiles.push({ fileName: expectation.file_name, bytes: captured })
	expectations.push(expectation)
}
const manifest = { household_members: householdMembers, documents: expectations }
generatedFiles.push({
	fileName: "expected_extraction.json",
	bytes: Buffer.from(`${JSON.stringify(manifest, null, "\t")}\n`),
})

await rm(outputDirectory, { recursive: true, force: true })
await mkdir(outputDirectory, { recursive: true })
for (const { fileName, bytes } of generatedFiles) {
	await writeFile(join(outputDirectory, fileName), bytes)
	console.log(`${fileName.padEnd(48)} ${(bytes.length / 1024).toFixed(0).padStart(5)} KiB`)
}
const totalBytes = generatedFiles.reduce((total, file) => total + file.bytes.length, 0)
console.log(`${generatedFiles.length} files, ${(totalBytes / 1024 / 1024).toFixed(2)} MiB in ${outputDirectory}`)
