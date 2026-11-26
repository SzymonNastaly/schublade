import { expect, test } from "vitest"
import { parseReceptionHeaders } from "./reception_headers"

const MAXIMUM_ORIGINAL_BYTES = 25_000_000

test("parseReceptionHeaders reads the counts of a body, or the refusal its headers earn", () => {
	const parse = (headers: Record<string, string>, query = "") =>
		parseReceptionHeaders(new Headers(headers), new URLSearchParams(query), MAXIMUM_ORIGINAL_BYTES)

	expect({
		originalAlone: parse({ "Content-Length": "1843233" }),
		withDerivedRepresentations: parse({
			"Content-Length": "1869412",
			"Schublade-Text-Byte-Count": "4180",
			"Schublade-Thumbnail-Byte-Count": "21999",
			"Schublade-Page-Count": "3",
		}),
		queryParameter: parse({ "Content-Length": "10" }, "text=1&text=2"),
		signedCount: parse({ "Content-Length": "10", "Schublade-Text-Byte-Count": "-1" }),
		noPage: parse({ "Content-Length": "10", "Schublade-Page-Count": "0" }),
		noContentLength: parse({}),
		noOriginal: parse({ "Content-Length": "4180", "Schublade-Text-Byte-Count": "4180" }),
		textTooLarge: parse({ "Content-Length": "2000011", "Schublade-Text-Byte-Count": "2000001" }),
		thumbnailTooLarge: parse({ "Content-Length": "200011", "Schublade-Thumbnail-Byte-Count": "200001" }),
		originalTooLarge: parse({ "Content-Length": "25004181", "Schublade-Text-Byte-Count": "4180" }),
	}).toEqual({
		originalAlone: {
			kind: "layout",
			layout: { textByteCount: 0, thumbnailByteCount: 0, originalByteCount: 1843233, pageCount: undefined },
		},
		withDerivedRepresentations: {
			kind: "layout",
			layout: { textByteCount: 4180, thumbnailByteCount: 21999, originalByteCount: 1843233, pageCount: 3 },
		},
		queryParameter: { kind: "refused", status: 400, detail: "This route defines no query parameter: text" },
		signedCount: {
			kind: "refused",
			status: 400,
			detail:
				"Schublade-Text-Byte-Count and Schublade-Thumbnail-Byte-Count must be decimal numbers, and Schublade-Page-Count a decimal number of at least 1",
		},
		noPage: {
			kind: "refused",
			status: 400,
			detail:
				"Schublade-Text-Byte-Count and Schublade-Thumbnail-Byte-Count must be decimal numbers, and Schublade-Page-Count a decimal number of at least 1",
		},
		noContentLength: { kind: "refused", status: 411, detail: "Send the body with a Content-Length" },
		noOriginal: {
			kind: "refused",
			status: 400,
			detail: "The body holds no byte of the original after the text and the thumbnail",
		},
		textTooLarge: { kind: "refused", status: 413, detail: "The text is larger than 2 MB" },
		thumbnailTooLarge: { kind: "refused", status: 413, detail: "The thumbnail is larger than 200 KB" },
		originalTooLarge: { kind: "refused", status: 413, detail: "The file is larger than 25 MB" },
	})
})
