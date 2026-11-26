// The evaluation scripts run this module in Node, which resolves a relative import only by its full name.
import { isReadableTextLayer } from "../ingestion/document_text.ts"
import { MAXIMUM_TEXT_BYTES, MAXIMUM_THUMBNAIL_BYTES } from "../ingestion/reception_headers.ts"
import { UNACCEPTED_FILE_KIND, identifySourceFile } from "../ingestion/source_file.ts"
import type { UploadOutcome } from "../ingestion/document_upload"
import type { SourceFile } from "../ingestion/source_file"
import type { PDFDocumentProxy } from "pdfjs-dist/legacy/build/pdf.mjs"

/**
 * What a sender read from a document: the text of each page in page order, empty for a page
 * without a readable text layer, and a JPEG of the first page. A picture has no page texts.
 */
export interface DerivedRepresentations {
	pageTexts: ReadonlyArray<string>
	thumbnail: Blob | undefined
}

type RepresentationReader = (
	content: Uint8Array<ArrayBuffer>,
	sourceFile: SourceFile,
) => Promise<DerivedRepresentations>

/** One PUT of the reception: the counted text and thumbnail, then the original. */
interface DocumentSubmission {
	path: string
	headers: Record<string, string>
	body: Blob
}

const STORAGE_FAILURE = "The archive could not store the file. Upload it again."

/**
 * The text of a document as the archive stores a text layer, as compose_document_text in
 * native_client/archive_access writes it: a `## Page N` heading for each page and each page's
 * text without its surrounding white space.
 */
function composeDocumentText(pageTexts: ReadonlyArray<string>): string {
	return pageTexts
		.map((text, index) => {
			const pageText = text.trim()
			return pageText === "" ? `## Page ${index + 1}\n` : `## Page ${index + 1}\n\n${pageText}\n`
		})
		.join("\n")
}

/** The text layer of each page through PDF.js, with a page the archive's rule calls unreadable left empty. */
export async function readPageTexts(pdf: PDFDocumentProxy): Promise<Array<string>> {
	const pageTexts: Array<string> = []
	for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber += 1) {
		const page = await pdf.getPage(pageNumber)
		const { items } = await page.getTextContent()
		const text = items.map((item) => ("str" in item ? item.str + (item.hasEOL ? "\n" : "") : "")).join("")
		pageTexts.push(isReadableTextLayer(text) ? text : "")
		page.cleanup()
	}
	return pageTexts
}

/**
 * The request for one document. A text is sent only when a page has one, and a text or a
 * thumbnail beyond the reception's limits is left out, so the archive reads the original itself.
 */
export function composeSubmission(
	original: Blob,
	sha256: string,
	{ pageTexts, thumbnail }: DerivedRepresentations,
): DocumentSubmission {
	const composedText = new TextEncoder().encode(composeDocumentText(pageTexts))
	const text =
		pageTexts.some((pageText) => pageText.trim() !== "") && composedText.byteLength <= MAXIMUM_TEXT_BYTES
			? composedText
			: new Uint8Array(0)
	const keptThumbnail = thumbnail !== undefined && thumbnail.size <= MAXIMUM_THUMBNAIL_BYTES ? thumbnail : new Blob()
	return {
		path: `/api/submitted_documents/${sha256}`,
		headers: {
			"Schublade-Text-Byte-Count": String(text.byteLength),
			"Schublade-Thumbnail-Byte-Count": String(keptThumbnail.size),
			...(pageTexts.length > 0 && { "Schublade-Page-Count": String(pageTexts.length) }),
		},
		body: new Blob([text, keptThumbnail, original]),
	}
}

const statusAnswerKinds: Partial<Record<number, "accepted" | "already_archived">> = {
	202: "accepted",
	200: "already_archived",
}

/** The reception's answer as the upload tray shows it. A refusal names its reason in a problem document. */
async function readSubmissionAnswer(response: Response, fileName: string): Promise<UploadOutcome> {
	const answerKind = statusAnswerKinds[response.status]
	if (answerKind !== undefined) {
		const { document_id: documentId } = await response.json<{ document_id: string }>()
		return { kind: answerKind, fileName, documentId }
	}
	if (response.status < 500 && response.headers.get("Content-Type") === "application/problem+json") {
		const { detail } = await response.json<{ detail: string }>()
		return { kind: "rejected", fileName, reason: detail }
	}
	return { kind: "failed", fileName, reason: STORAGE_FAILURE }
}

/**
 * Reads one file and sends it with what readRepresentations derived. A reader that fails holds
 * back nothing: the file goes without a text and a thumbnail, and the archive reads it itself.
 */
export async function submitDocument(
	file: File,
	readRepresentations: RepresentationReader,
	archiveOrigin = "",
): Promise<UploadOutcome> {
	// A file removed or changed since it was chosen cannot be read.
	const content = await file.arrayBuffer().then(
		(buffer) => new Uint8Array(buffer),
		() => undefined,
	)
	if (content === undefined) {
		return { kind: "failed", fileName: file.name, reason: "The file could not be read. Choose it again." }
	}
	const sourceFile = identifySourceFile(content)
	if (!sourceFile) return { kind: "rejected", fileName: file.name, reason: UNACCEPTED_FILE_KIND }
	const digest = await crypto.subtle.digest("SHA-256", content)
	const sha256 = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
	const derived = await readRepresentations(content, sourceFile).catch((error: unknown) => {
		console.warn(`Reading ${file.name} failed, so the archive reads it`, error)
		return { pageTexts: [], thumbnail: undefined }
	})
	const { path, headers, body } = composeSubmission(file, sha256, derived)
	try {
		const response = await fetch(`${archiveOrigin}${path}`, { method: "PUT", headers, body })
		return await readSubmissionAnswer(response, file.name)
	} catch (error) {
		console.error(`Sending ${file.name} failed`, error)
		return { kind: "failed", fileName: file.name, reason: STORAGE_FAILURE }
	}
}
