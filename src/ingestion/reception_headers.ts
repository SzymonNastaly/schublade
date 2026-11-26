// The limits of the representations a client derives. A text this long belongs to a PDF with a
// text layer, which the archive reads itself, and a JPEG of 480 pixels on its longer side stays
// far below the thumbnail limit.
export const MAXIMUM_TEXT_BYTES = 2_000_000
export const MAXIMUM_THUMBNAIL_BYTES = 200_000

/**
 * The byte counts of one reception body: the Markdown text, then the JPEG thumbnail, then the
 * original, with no separator. A count of 0 means the client sent no such representation.
 */
export interface ReceptionLayout {
	textByteCount: number
	thumbnailByteCount: number
	originalByteCount: number
	/** The number of pages the client read, absent when it sent none. */
	pageCount: number | undefined
}

export type ReceptionHeaders =
	{ kind: "layout"; layout: ReceptionLayout } | { kind: "refused"; status: 400 | 411 | 413; detail: string }

function decimalHeader(headers: Headers, name: string): number | undefined | "malformed" {
	const value = headers.get(name)
	if (value === null) return undefined
	return /^\d{1,10}$/.test(value) ? Number(value) : "malformed"
}

/**
 * Reads the layout of a reception body from its headers alone, so every refusal comes before
 * the body is read.
 */
export function parseReceptionHeaders(
	headers: Headers,
	searchParams: URLSearchParams,
	maximumOriginalBytes: number,
): ReceptionHeaders {
	const parameters = [...new Set(searchParams.keys())]
	if (parameters.length > 0) {
		return { kind: "refused", status: 400, detail: `This route defines no query parameter: ${parameters.join(", ")}` }
	}
	const textByteCount = decimalHeader(headers, "Schublade-Text-Byte-Count")
	const thumbnailByteCount = decimalHeader(headers, "Schublade-Thumbnail-Byte-Count")
	const pageCount = decimalHeader(headers, "Schublade-Page-Count")
	if (
		textByteCount === "malformed" ||
		thumbnailByteCount === "malformed" ||
		pageCount === "malformed" ||
		pageCount === 0
	) {
		return {
			kind: "refused",
			status: 400,
			detail:
				"Schublade-Text-Byte-Count and Schublade-Thumbnail-Byte-Count must be decimal numbers, and Schublade-Page-Count a decimal number of at least 1",
		}
	}
	const contentLength = decimalHeader(headers, "Content-Length")
	if (contentLength === undefined) {
		return { kind: "refused", status: 411, detail: "Send the body with a Content-Length" }
	}
	if (contentLength === "malformed") {
		return { kind: "refused", status: 400, detail: "Content-Length must be a decimal number" }
	}
	const layout: ReceptionLayout = {
		textByteCount: textByteCount ?? 0,
		thumbnailByteCount: thumbnailByteCount ?? 0,
		originalByteCount: contentLength - (textByteCount ?? 0) - (thumbnailByteCount ?? 0),
		pageCount,
	}
	if (layout.originalByteCount <= 0) {
		return {
			kind: "refused",
			status: 400,
			detail: "The body holds no byte of the original after the text and the thumbnail",
		}
	}
	if (layout.textByteCount > MAXIMUM_TEXT_BYTES) {
		return { kind: "refused", status: 413, detail: `The text is larger than ${MAXIMUM_TEXT_BYTES / 1_000_000} MB` }
	}
	if (layout.thumbnailByteCount > MAXIMUM_THUMBNAIL_BYTES) {
		return { kind: "refused", status: 413, detail: `The thumbnail is larger than ${MAXIMUM_THUMBNAIL_BYTES / 1000} KB` }
	}
	if (layout.originalByteCount > maximumOriginalBytes) {
		return { kind: "refused", status: 413, detail: `The file is larger than ${maximumOriginalBytes / 1_000_000} MB` }
	}
	return { kind: "layout", layout }
}
