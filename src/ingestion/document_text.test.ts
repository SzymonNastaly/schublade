import { expect, test } from "vitest"
import { assembleDocumentMarkdown, pagesWithoutTextLayer } from "./document_text"

test("pagesWithoutTextLayer selects pages with fewer than 40 text layer characters", () => {
	expect(
		pagesWithoutTextLayer([
			{ pageIndex: 0, textCharacterCount: 1200 },
			{ pageIndex: 1, textCharacterCount: 39 },
			{ pageIndex: 2, textCharacterCount: 40 },
			{ pageIndex: 3, textCharacterCount: 0 },
		]),
	).toEqual([1, 3])
})

test("assembleDocumentMarkdown appends recognized pages to the text layer and drops an empty conversion", () => {
	const transcription = { pageIndex: 1, text: "Gesamtbetrag 72,09 €" }
	expect([
		assembleDocumentMarkdown(
			{ pageCount: 2, convertedMarkdown: "# original.pdf\n### Page 1\nRechnung\n", pagesRequiringRecognition: [1] },
			[transcription],
		),
		assembleDocumentMarkdown(
			{
				pageCount: 2,
				convertedMarkdown: "# original.pdf\n### Page 1\n\n### Page 2\n",
				pagesRequiringRecognition: [0, 1],
			},
			[{ pageIndex: 0, text: "Bescheid" }, transcription],
		),
	]).toEqual([
		"# original.pdf\n### Page 1\nRechnung\n\n## Page 2\n\nGesamtbetrag 72,09 €",
		"## Page 1\n\nBescheid\n\n## Page 2\n\nGesamtbetrag 72,09 €",
	])
})
