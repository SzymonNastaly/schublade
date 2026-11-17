import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { init as initializePdfium } from "@embedpdf/pdfium"
import jpeg from "jpeg-js"
import PDFDocument from "pdfkit"
import { letterMargins, syntheticNotice, typefaceFiles } from "./document_layout.ts"
import type { ColorRaster, GrayscaleRaster } from "./capture_simulation.ts"
import type { DocumentSpecification, PageSize, PrintedMatter } from "./document_layout.ts"

export type Pdfium = Awaited<ReturnType<typeof initializePdfium>>

export interface PdfInformation {
	creator: string
	creationDate: Date
}

export interface ImagePage {
	jpeg: Buffer
	size: PageSize
}

export async function loadPdfium(): Promise<Pdfium> {
	const pdfium = await initializePdfium({
		wasmBinary: Uint8Array.from(readFileSync(fileURLToPath(import.meta.resolve("@embedpdf/pdfium/pdfium.wasm"))))
			.buffer,
	})
	pdfium.PDFiumExt_Init()
	return pdfium
}

function withLoadedPdf<TResult>(
	pdfium: Pdfium,
	bytes: Uint8Array,
	inspect: (documentHandle: number) => TResult,
): TResult {
	const runtime = pdfium.pdfium
	const pointer = runtime.wasmExports.malloc(bytes.length)
	runtime.HEAPU8.set(bytes, pointer)
	const documentHandle = pdfium.FPDF_LoadMemDocument(pointer, bytes.length, "")
	try {
		if (!documentHandle) throw new Error(`PDFium could not load the document (error ${pdfium.FPDF_GetLastError()})`)
		return inspect(documentHandle)
	} finally {
		if (documentHandle) pdfium.FPDF_CloseDocument(documentHandle)
		runtime.wasmExports.free(pointer)
	}
}

export function extractPageTexts(pdfium: Pdfium, bytes: Uint8Array): Array<string> {
	return withLoadedPdf(pdfium, bytes, (documentHandle) =>
		Array.from({ length: pdfium.FPDF_GetPageCount(documentHandle) }, (_, pageIndex) => {
			const page = pdfium.FPDF_LoadPage(documentHandle, pageIndex)
			const textPage = pdfium.FPDFText_LoadPage(page)
			const characterCount = pdfium.FPDFText_CountChars(textPage)
			const buffer = pdfium.pdfium.wasmExports.malloc((characterCount + 1) * 2)
			pdfium.FPDFText_GetText(textPage, 0, characterCount, buffer)
			const text = characterCount > 0 ? pdfium.pdfium.UTF16ToString(buffer) : ""
			pdfium.pdfium.wasmExports.free(buffer)
			pdfium.FPDFText_ClosePage(textPage)
			pdfium.FPDF_ClosePage(page)
			return text
		}),
	)
}

export function rasterizePages(pdfium: Pdfium, bytes: Uint8Array, dotsPerInch: number): Array<GrayscaleRaster> {
	const bitmapFormatBlueGreenRedAlpha = 4
	return withLoadedPdf(pdfium, bytes, (documentHandle) =>
		Array.from({ length: pdfium.FPDF_GetPageCount(documentHandle) }, (_, pageIndex) => {
			const page = pdfium.FPDF_LoadPage(documentHandle, pageIndex)
			const width = Math.round((pdfium.FPDF_GetPageWidthF(page) * dotsPerInch) / 72)
			const height = Math.round((pdfium.FPDF_GetPageHeightF(page) * dotsPerInch) / 72)
			const bitmap = pdfium.FPDFBitmap_CreateEx(width, height, bitmapFormatBlueGreenRedAlpha, 0, 0)
			pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xffffffff)
			pdfium.FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0)
			const bufferPointer = pdfium.FPDFBitmap_GetBuffer(bitmap)
			const stride = pdfium.FPDFBitmap_GetStride(bitmap)
			const heap = pdfium.pdfium.HEAPU8
			const luminance = new Uint8Array(width * height)
			for (let y = 0; y < height; y++) {
				for (let x = 0; x < width; x++) {
					const pixel = bufferPointer + y * stride + x * 4
					luminance[y * width + x] = (heap[pixel]! * 29 + heap[pixel + 1]! * 150 + heap[pixel + 2]! * 77) >> 8
				}
			}
			pdfium.FPDFBitmap_Destroy(bitmap)
			pdfium.FPDF_ClosePage(page)
			return { width, height, luminance }
		}),
	)
}

function documentInformation(information: PdfInformation): PDFKit.DocumentInfo {
	return {
		Title: "Synthetic test document",
		Subject: syntheticNotice,
		Keywords: "synthetic, fictional, test fixture",
		Creator: information.creator,
		Producer: "Schublade synthetic test document generator",
		CreationDate: information.creationDate,
		ModDate: information.creationDate,
	}
}

function collectPdf(document: PDFKit.PDFDocument): Promise<Buffer> {
	return new Promise((resolve, reject) => {
		const chunks: Array<Buffer> = []
		document.on("data", (chunk: Buffer) => chunks.push(chunk))
		document.on("end", () => resolve(Buffer.concat(chunks)))
		document.on("error", reject)
		document.end()
	})
}

export function renderSourcePdf(matter: PrintedMatter, information: PdfInformation): Promise<Buffer> {
	const document = new PDFDocument({
		autoFirstPage: false,
		size: [...matter.pageSize],
		margins: letterMargins,
		compress: false,
		info: documentInformation(information),
	})
	for (const [name, modulePath] of Object.entries(typefaceFiles)) {
		document.registerFont(name, fileURLToPath(import.meta.resolve(modulePath)))
	}
	matter.render(document)
	return collectPdf(document)
}

export function composeImagePdf(pages: ReadonlyArray<ImagePage>, information: PdfInformation): Promise<Buffer> {
	const document = new PDFDocument({ autoFirstPage: false, compress: false, info: documentInformation(information) })
	for (const { jpeg: jpegPage, size } of pages) {
		const [pageWidth, pageHeight] = size
		document.addPage({ size: [pageWidth, pageHeight], margin: 0 })
		document.image(jpegPage, 0, 0, { width: pageWidth, height: pageHeight })
	}
	return collectPdf(document)
}

export const encodeJpeg = (raster: ColorRaster, quality: number): Buffer =>
	jpeg.encode({ width: raster.width, height: raster.height, data: raster.rgba, comments: [syntheticNotice] }, quality)
		.data

function hasValidIbanChecksum(iban: string): boolean {
	const compact = iban.replace(/ /g, "")
	const digits = `${compact.slice(4)}${compact.slice(0, 4)}`.replace(/[A-Z]/g, (letter) =>
		String(letter.charCodeAt(0) - 55),
	)
	return BigInt(digits) % 97n === 1n
}

export function verifySourcePdf(
	label: string,
	specification: DocumentSpecification,
	pageTexts: ReadonlyArray<string>,
): void {
	const failures: Array<string> = []
	if (pageTexts.length !== specification.pageCount)
		failures.push(`declares ${specification.pageCount} pages but renders ${pageTexts.length}`)
	const text = pageTexts.join(" ").replace(/\s+/g, " ")
	const printedValues: Array<[string, string]> = [
		["sender", specification.sender],
		["document_date", specification.documentDate.printed],
		...Object.entries(specification.fields).map(([key, field]): [string, string] => [key, field.printed]),
	]
	if (specification.person !== "household")
		printedValues.push(...specification.person.split(" ").map((namePart): [string, string] => ["person", namePart]))
	for (const [printedLabel, printed] of printedValues) {
		if (!text.includes(printed)) failures.push(`${printedLabel} "${printed}" is not printed`)
	}
	for (const [printedIban] of text.matchAll(/\b[A-Z]{2}\d{2}(?: ?[0-9A-Z]{4}){3,7}(?: ?[0-9A-Z]{1,3})?\b/g)) {
		if (!hasValidIbanChecksum(printedIban)) failures.push(`IBAN "${printedIban}" fails the ISO 13616 checksum`)
	}
	if (failures.length > 0) throw new Error(`${label}: ${failures.join("; ")}`)
}
