import type { PageInspection } from "../inference/page_rasterizer"

// VISION.md: a scanned page yields fewer than 40 characters from its text layer.
const MINIMUM_ALPHANUMERIC_CHARACTERS = 40

const ALPHANUMERIC_CHARACTER = /[\p{L}\p{N}]/gu
// What a glyph without a usable Unicode mapping comes out as: U+FFFD, a private use code point, or a
// control character other than tab, line feed, and carriage return.
const REPLACEMENT_CHARACTER = /[\uFFFD\p{Co}]|(?![\t\n\r])\p{Cc}/gu

/**
 * Where the text of a page comes from: its section of the `toMarkdown()` conversion, the text layer
 * as PDFium extracts it, or a Moondream transcription of the rendered page.
 */
export type PageTextSource =
	| { kind: "converted"; pageIndex: number }
	| { kind: "text_layer"; pageIndex: number; text: string }
	| { kind: "recognition"; pageIndex: number }

export interface TextExtraction {
	/** Markdown from `toMarkdown()`, with a `### Page N` section for each page. */
	convertedMarkdown: string
	pages: Array<PageTextSource>
}

export interface PageTranscription {
	pageIndex: number
	text: string
}

const PAGE_HEADING = /^### Page (\d+)\s*$/gm

function countMatches(text: string, pattern: RegExp): number {
	return text.match(pattern)?.length ?? 0
}

/** Text of each `### Page N` section of the `toMarkdown()` output, keyed by page index. */
function convertedSectionsByPage(convertedMarkdown: string): Map<number, string> {
	const headings = [...convertedMarkdown.matchAll(PAGE_HEADING)]
	return new Map(
		headings.map((heading, position) => [
			Number(heading[1]) - 1,
			convertedMarkdown.slice(heading.index + heading[0].length, headings[position + 1]?.index),
		]),
	)
}

/**
 * A text layer is readable when it holds at least 40 letters or digits and fewer than one
 * replacement character per ten of them. A few symbol font bullets pass; a font without a Unicode
 * mapping, whose glyphs come out as replacement characters, sends the page to recognition.
 */
function isReadableTextLayer(text: string): boolean {
	const alphanumericCount = countMatches(text, ALPHANUMERIC_CHARACTER)
	return (
		alphanumericCount >= MINIMUM_ALPHANUMERIC_CHARACTERS &&
		countMatches(text, REPLACEMENT_CHARACTER) * 10 < alphanumericCount
	)
}

/**
 * Takes the text of each page from the first source that holds it: the converted section, which
 * keeps tables as Markdown, then the PDFium text layer, then Moondream. `toMarkdown()` returns empty
 * sections for tagged PDFs whose structure tree it cannot follow, although PDFium reads their text
 * layer in full, so such a page costs no rendering and no billed recognition.
 */
export function selectPageTextSources(
	pages: ReadonlyArray<PageInspection>,
	convertedMarkdown: string,
): Array<PageTextSource> {
	const convertedSections = convertedSectionsByPage(convertedMarkdown)
	return pages.map(({ pageIndex, text }) => {
		const convertedSection = convertedSections.get(pageIndex) ?? ""
		if (countMatches(convertedSection, ALPHANUMERIC_CHARACTER) >= MINIMUM_ALPHANUMERIC_CHARACTERS) {
			return { kind: "converted", pageIndex }
		}
		if (isReadableTextLayer(text)) return { kind: "text_layer", pageIndex, text }
		return { kind: "recognition", pageIndex }
	})
}

// Each transcribed page costs one Moondream call and one workflow step, so a long scan is
// refused before its first page is transcribed rather than after paying for every page.
const MAXIMUM_RECOGNIZED_PAGES = 50

export function recognitionLimitViolation(pages: ReadonlyArray<PageTextSource>): string | undefined {
	const recognizedPageCount = pages.filter((page) => page.kind === "recognition").length
	if (recognizedPageCount <= MAXIMUM_RECOGNIZED_PAGES) return undefined
	return `The document has ${recognizedPageCount} pages without a readable text layer, and at most ${MAXIMUM_RECOGNIZED_PAGES} are transcribed`
}

/**
 * Pages read from the text layer or recognized follow the converted Markdown in page order. When
 * no page was taken from the conversion, it holds only headings, so it is left out.
 */
export function assembleDocumentMarkdown(
	extraction: TextExtraction,
	transcriptions: ReadonlyArray<PageTranscription>,
): string {
	const hasConvertedPage = extraction.pages.some((page) => page.kind === "converted")
	const pageTexts = [
		...extraction.pages.flatMap((page) => (page.kind === "text_layer" ? [page] : [])),
		...transcriptions,
	].sort((first, second) => first.pageIndex - second.pageIndex)
	const sections = [
		hasConvertedPage ? extraction.convertedMarkdown.trim() : "",
		...pageTexts.map((page) => `## Page ${page.pageIndex + 1}\n\n${page.text}`),
	]
	return sections.filter((section) => section !== "").join("\n\n")
}
