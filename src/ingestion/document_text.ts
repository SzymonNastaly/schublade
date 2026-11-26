// A scanned page yields fewer than 40 characters from its text layer.
const MINIMUM_ALPHANUMERIC_CHARACTERS = 40

const ALPHANUMERIC_CHARACTER = /[\p{L}\p{N}]/gu
// What a glyph without a usable Unicode mapping comes out as: U+FFFD, a private use code point, or a
// control character other than tab, line feed, and carriage return.
const REPLACEMENT_CHARACTER = /[\uFFFD\p{Co}]|(?![\t\n\r])\p{Cc}/gu

const PAGE_HEADING = /^### Page (\d+)\s*$/gm

function countMatches(text: string, pattern: RegExp): number {
	return text.match(pattern)?.length ?? 0
}

/**
 * The text of each `### Page N` section of a `toMarkdown()` conversion, in page order. The lines
 * above the first section name the file, so they are no text of the document.
 */
export function convertedPageTexts(convertedMarkdown: string): Array<string> {
	const headings = [...convertedMarkdown.matchAll(PAGE_HEADING)]
	return headings.map((heading, position) =>
		convertedMarkdown.slice(heading.index + heading[0].length, headings[position + 1]?.index),
	)
}

/**
 * A text layer is readable when it holds at least 40 letters or digits and fewer than one
 * replacement character per ten of them. A few symbol font bullets pass; a font without a Unicode
 * mapping, whose glyphs come out as replacement characters, leaves the page to recognition on the device.
 */
export function isReadableTextLayer(text: string): boolean {
	const alphanumericCount = countMatches(text, ALPHANUMERIC_CHARACTER)
	return (
		alphanumericCount >= MINIMUM_ALPHANUMERIC_CHARACTERS &&
		countMatches(text, REPLACEMENT_CHARACTER) * 10 < alphanumericCount
	)
}

/**
 * Whether a text holds at least 40 letters or digits, so the archive takes it as the document's
 * text. The count stops at the 40th, so a long text costs nothing.
 */
export function holdsUsableText(text: string): boolean {
	let alphanumericCount = 0
	for (const _ of text.matchAll(ALPHANUMERIC_CHARACTER)) {
		alphanumericCount += 1
		if (alphanumericCount >= MINIMUM_ALPHANUMERIC_CHARACTERS) return true
	}
	return false
}
