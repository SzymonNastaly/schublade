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

const PAGE_HEADING = /^### Page (\d+)\s*$/gm

/** Letters and digits per page of the `toMarkdown()` output, keyed by page index. */
function convertedCharactersByPage(convertedMarkdown: string): Map<number, number> {
	const headings = [...convertedMarkdown.matchAll(PAGE_HEADING)]
	const counts = new Map<number, number>()
	headings.forEach((heading, position) => {
		const sectionStart = heading.index + heading[0].length
		const sectionEnd = headings[position + 1]?.index ?? convertedMarkdown.length
		const section = convertedMarkdown.slice(sectionStart, sectionEnd)
		counts.set(Number(heading[1]) - 1, section.match(/[\p{L}\p{N}]/gu)?.length ?? 0)
	})
	return counts
}

/**
 * A page is transcribed when its text layer is sparse, or when `toMarkdown()` could not read the
 * layer: a ticket on staging had 40 or more PDFium characters on its page and an empty page section
 * in the conversion, so the classifier saw no text. Without page headings in the conversion, only
 * the text layer decides, so a conversion in another layout never sends every page to OCR.
 */
export function pagesRequiringRecognition(
	pages: ReadonlyArray<PageInspection>,
	convertedMarkdown: string,
): Array<number> {
	const convertedCharacters = convertedCharactersByPage(convertedMarkdown)
	return pages
		.filter(
			(page) =>
				page.textCharacterCount < MINIMUM_TEXT_LAYER_CHARACTERS ||
				(convertedCharacters.size > 0 &&
					(convertedCharacters.get(page.pageIndex) ?? 0) < MINIMUM_TEXT_LAYER_CHARACTERS),
		)
		.map((page) => page.pageIndex)
}

// Each transcribed page costs one Moondream call and one workflow step, so a long scan is
// refused before its first page is transcribed rather than after paying for every page.
const MAXIMUM_RECOGNIZED_PAGES = 50

export function recognitionLimitViolation(pageIndexes: ReadonlyArray<number>): string | undefined {
	if (pageIndexes.length <= MAXIMUM_RECOGNIZED_PAGES) return undefined
	return `The document has ${pageIndexes.length} pages without a text layer, and at most ${MAXIMUM_RECOGNIZED_PAGES} are transcribed`
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
