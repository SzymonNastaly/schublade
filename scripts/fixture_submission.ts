import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs"
import { readPageTexts, submitDocument } from "../src/interface/document_reading.ts"
import type { UploadOutcome } from "../src/ingestion/document_upload.ts"

/**
 * Sends a test document as the web application does: a PDF with the page texts PDF.js reads, and
 * a picture alone. Node has no canvas, so the document has no thumbnail.
 */
export function submitFixtureDocument(baseUrl: string, file: File): Promise<UploadOutcome> {
	return submitDocument(
		file,
		async (content, sourceFile) => ({
			pageTexts: sourceFile.kind === "pdf" ? await readPageTexts(await getDocument({ data: content }).promise) : [],
			thumbnail: undefined,
		}),
		baseUrl,
	)
}
