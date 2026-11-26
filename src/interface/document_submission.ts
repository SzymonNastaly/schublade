import { readPageTexts, submitDocument } from "./document_reading"
import { preparePdfOpener } from "./pdf_opening"
import type { DerivedRepresentations } from "./document_reading"
import type { SourceFile } from "../ingestion/source_file"
import type { UploadOutcome } from "../ingestion/document_upload"
import type { PDFDocumentProxy } from "pdfjs-dist/legacy/build/pdf.mjs"

// The archive's lists were built for its own drawing of an A4 page, 331 by 468 pixels.
const THUMBNAIL_LONGER_SIDE = 480
const THUMBNAIL_QUALITY = 0.8
// Each submission holds its file in memory while it reads and sends it.
const MAXIMUM_CONCURRENT_SUBMISSIONS = 3

function encodeThumbnail(canvas: HTMLCanvasElement): Promise<Blob | undefined> {
	return new Promise((resolve) => canvas.toBlob((blob) => resolve(blob ?? undefined), "image/jpeg", THUMBNAIL_QUALITY))
}

async function drawFirstPage(pdf: PDFDocumentProxy): Promise<Blob | undefined> {
	const page = await pdf.getPage(1)
	const { width, height } = page.getViewport({ scale: 1 })
	const viewport = page.getViewport({ scale: THUMBNAIL_LONGER_SIDE / Math.max(width, height) })
	const canvas = document.createElement("canvas")
	canvas.width = Math.round(viewport.width)
	canvas.height = Math.round(viewport.height)
	// PDF.js paints the page on white.
	await page.render({ canvas, viewport }).promise
	return encodeThumbnail(canvas)
}

/** The picture upright, as its orientation tag says, on white, and never enlarged. */
async function drawPicture(picture: Blob): Promise<Blob | undefined> {
	const bitmap = await createImageBitmap(picture)
	const scale = Math.min(1, THUMBNAIL_LONGER_SIDE / Math.max(bitmap.width, bitmap.height))
	const canvas = document.createElement("canvas")
	canvas.width = Math.max(1, Math.round(bitmap.width * scale))
	canvas.height = Math.max(1, Math.round(bitmap.height * scale))
	const context = canvas.getContext("2d")
	if (context === null) return undefined
	context.fillStyle = "white"
	context.fillRect(0, 0, canvas.width, canvas.height)
	context.imageSmoothingQuality = "high"
	context.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
	bitmap.close()
	return encodeThumbnail(canvas)
}

/**
 * PDF.js reads the text and draws the first page in its own workers, so a long PDF leaves the
 * page responsive. A picture has no text in the browser, and the archive reads it itself.
 */
async function readBrowserRepresentations(
	content: Uint8Array<ArrayBuffer>,
	sourceFile: SourceFile,
): Promise<DerivedRepresentations> {
	if (sourceFile.kind === "image") {
		return { pageTexts: [], thumbnail: await drawPicture(new Blob([content], { type: sourceFile.mediaType })) }
	}
	const openPdf = await preparePdfOpener()
	// PDF.js takes over the buffer it opens, and the digest was computed before.
	const loadingTask = openPdf(content)
	try {
		const pdf = await loadingTask.promise
		const pageTexts = await readPageTexts(pdf)
		const thumbnail = await drawFirstPage(pdf).catch((error: unknown) => {
			console.warn("PDF.js could not draw the first page", error)
			return undefined
		})
		return { pageTexts, thumbnail }
	} finally {
		void loadingTask.destroy()
	}
}

let activeSubmissions = 0
const awaitingSubmissions: Array<() => void> = []

async function acquireSubmissionSlot(): Promise<void> {
	if (activeSubmissions < MAXIMUM_CONCURRENT_SUBMISSIONS) {
		activeSubmissions += 1
		return
	}
	// A finishing submission hands its slot on directly.
	await new Promise<void>((resolve) => awaitingSubmissions.push(resolve))
}

function releaseSubmissionSlot() {
	const next = awaitingSubmissions.shift()
	if (next) next()
	else activeSubmissions -= 1
}

/** Reads and sends one file from the browser, at most three files of the tab at once. */
export async function submitBrowserDocument(file: File): Promise<UploadOutcome> {
	await acquireSubmissionSlot()
	try {
		return await submitDocument(file, readBrowserRepresentations)
	} finally {
		releaseSubmissionSlot()
	}
}
