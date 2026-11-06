import type { PageInspection } from "../inference/page_rasterizer"

// VISION.md: a scanned page yields fewer than 40 characters from its text layer.
const MINIMUM_TEXT_LAYER_CHARACTERS = 40

export interface TextExtraction {
	pageCount: number
	/** Markdown from `toMarkdown()`, which holds the text layer of every page that has one. */
	convertedMarkdown: string
	pagesRequiringRecognition: Array<number>
}

export interface PageTranscription {
	pageIndex: number
	text: string
}

export function pagesWithoutTextLayer(pages: ReadonlyArray<PageInspection>): Array<number> {
	return pages.filter((page) => page.textCharacterCount < MINIMUM_TEXT_LAYER_CHARACTERS).map((page) => page.pageIndex)
}

/**
 * Recognized pages follow the converted Markdown in page order. When every page needed
 * recognition, the conversion holds only headings, so it is left out.
 */
export function assembleDocumentMarkdown(
	extraction: TextExtraction,
	transcriptions: ReadonlyArray<PageTranscription>,
): string {
	const hasTextLayerPage = extraction.pagesRequiringRecognition.length < extraction.pageCount
	const sections = [
		hasTextLayerPage ? extraction.convertedMarkdown.trim() : "",
		...transcriptions.map((transcription) => `## Page ${transcription.pageIndex + 1}\n\n${transcription.text}`),
	]
	return sections.filter((section) => section !== "").join("\n\n")
}
