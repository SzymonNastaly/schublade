import { expect, test } from "vitest"
import {
	assembleDocumentMarkdown,
	recognitionLimitViolation,
	selectPageTextSources,
	selectPrintedMailTextSources,
} from "./document_text"

test("recognitionLimitViolation transcribes up to 50 pages and refuses a 51st, counting only transcribed pages", () => {
	const pages = (recognizedPageCount: number) => [
		...Array.from({ length: 10 }, (_, index) => ({ kind: "converted" as const, pageIndex: index })),
		...Array.from({ length: recognizedPageCount }, (_, index) => ({
			kind: "recognition" as const,
			pageIndex: 10 + index,
		})),
	]
	expect(recognitionLimitViolation(pages(50))).toBe(undefined)
	expect(recognitionLimitViolation(pages(51))).toBe(
		"The document has 51 pages without a readable text layer, and at most 50 are transcribed",
	)
})

test("selectPageTextSources reads a page from its text layer when its converted section is empty", () => {
	const invoiceText = "Rechnung Nordkabel Kommunikation GmbH, Rechnungsnummer NK-2026-1048-3391, Betrag 67,13 EUR"
	const ticketText = "Fahrkarte Hamburg Hbf – Berlin Hbf\nHinfahrt am 14.11.2026, Auftragsnummer Q7K2M9\nPreis 59,90 €"
	const convertedMarkdown = ["# original.pdf", "## Contents", "### Page 1", "", invoiceText, "### Page 2", "", ""].join(
		"\n",
	)
	expect(
		selectPageTextSources(
			[
				{ pageIndex: 0, textCharacterCount: 90, text: invoiceText },
				{ pageIndex: 1, textCharacterCount: 94, text: ticketText },
			],
			convertedMarkdown,
		),
	).toEqual([
		{ kind: "converted", pageIndex: 0 },
		{
			kind: "text_layer",
			pageIndex: 1,
			text: "Fahrkarte Hamburg Hbf – Berlin Hbf\nHinfahrt am 14.11.2026, Auftragsnummer Q7K2M9\nPreis 59,90 €",
		},
	])
})

test("selectPageTextSources reads a page from its text layer when its converted section holds under 90% of it", () => {
	const printedHeader = "Subject: Fwd: Your receipt from Paperlark\nFrom: mira@example.com\n"
	const receiptBody = "Paperlark GmbH, order 4821, three notebooks, total 12,99 EUR, paid by card\n".repeat(2)
	const matchingText = "Rechnung Nordkabel Kommunikation GmbH, Rechnungsnummer NK-2026-1048-3391"
	expect(
		selectPageTextSources(
			[
				{ pageIndex: 0, textCharacterCount: 214, text: printedHeader + receiptBody },
				{ pageIndex: 1, textCharacterCount: 72, text: matchingText },
			],
			`# original.pdf\n## Contents\n### Page 1\n\n${printedHeader}\n### Page 2\n\n${matchingText}\n`,
		),
	).toEqual([
		{ kind: "text_layer", pageIndex: 0, text: printedHeader + receiptBody },
		{ kind: "converted", pageIndex: 1 },
	])
})

test("selectPrintedMailTextSources reads every page from the text layer unless the message adds under 40 letters or digits", () => {
	const printedHeader = "Subject: Your receipt from Paperlark\nFrom: mira@example.com\nDate: 2026-11-08T16:50:51.000Z"
	const body = "Paperlark GmbH, order 4821, total 12,99 EUR"
	expect([
		selectPrintedMailTextSources(
			[
				{ pageIndex: 0, textCharacterCount: 132, text: `${printedHeader}\n${body}` },
				{ pageIndex: 1, textCharacterCount: 6, text: "Thanks" },
			],
			printedHeader,
		),
		selectPrintedMailTextSources(
			[{ pageIndex: 0, textCharacterCount: 96, text: `${printedHeader}\nHallo` }],
			printedHeader,
		),
	]).toEqual([
		[
			{ kind: "text_layer", pageIndex: 0, text: `${printedHeader}\n${body}` },
			{ kind: "text_layer", pageIndex: 1, text: "Thanks" },
		],
		[{ kind: "recognition", pageIndex: 0 }],
	])
})

test("selectPageTextSources transcribes a page whose converted section and text layer both hold fewer than 40 letters or digits", () => {
	const fortyLettersAndDigits = "Seite 1 von 1\n".repeat(4)
	expect(
		selectPageTextSources(
			[
				{ pageIndex: 0, textCharacterCount: 56, text: fortyLettersAndDigits },
				{ pageIndex: 1, textCharacterCount: 55, text: fortyLettersAndDigits.slice(1) },
			],
			"# original.pdf\n## Contents\n### Page 1\n\nSeite 1 von 1\n### Page 2\n\nSeite 1 von 1\n",
		),
	).toEqual([
		{ kind: "text_layer", pageIndex: 0, text: "Seite 1 von 1\nSeite 1 von 1\nSeite 1 von 1\nSeite 1 von 1\n" },
		{ kind: "recognition", pageIndex: 1 },
	])
})

test("selectPageTextSources transcribes a page whose text layer holds a replacement character per ten letters or digits", () => {
	const fiftyLettersAndDigits = "Betrag 67,13\n".repeat(5)
	const bulletedList = "\uF0B7 Betrag 67,13\n".repeat(4)
	expect(
		selectPageTextSources(
			[
				{ pageIndex: 0, textCharacterCount: 465, text: fiftyLettersAndDigits + "\uFFFD".repeat(400) },
				{ pageIndex: 1, textCharacterCount: 74, text: `${bulletedList}\u0003Betrag 67,13\n` },
				{ pageIndex: 2, textCharacterCount: 74, text: `${bulletedList}Betrag 67,13\t\n` },
			],
			"# original.pdf\n## Contents\n### Page 1\n\n### Page 2\n\n### Page 3\n\n",
		),
	).toEqual([
		{ kind: "recognition", pageIndex: 0 },
		{ kind: "recognition", pageIndex: 1 },
		{
			kind: "text_layer",
			pageIndex: 2,
			text: "\uF0B7 Betrag 67,13\n\uF0B7 Betrag 67,13\n\uF0B7 Betrag 67,13\n\uF0B7 Betrag 67,13\nBetrag 67,13\t\n",
		},
	])
})

test("assembleDocumentMarkdown keeps the conversion only when a page was taken from it", () => {
	const ticketText = "Fahrkarte Hamburg Hbf – Berlin Hbf"
	expect([
		assembleDocumentMarkdown(
			{
				convertedMarkdown: "# original.pdf\n### Page 1\nRechnung\n### Page 2\n\n### Page 3\n",
				pages: [
					{ kind: "converted", pageIndex: 0 },
					{ kind: "text_layer", pageIndex: 1, text: ticketText },
					{ kind: "recognition", pageIndex: 2 },
				],
			},
			[{ pageIndex: 2, text: "Gesamtbetrag 72,09 €" }],
		),
		assembleDocumentMarkdown(
			{
				convertedMarkdown: "# original.pdf\n## Contents\n### Page 1\n\n\n",
				pages: [{ kind: "text_layer", pageIndex: 0, text: ticketText }],
			},
			[],
		),
	]).toEqual([
		"# original.pdf\n### Page 1\nRechnung\n### Page 2\n\n### Page 3\n\n## Page 2\n\nFahrkarte Hamburg Hbf – Berlin Hbf\n\n## Page 3\n\nGesamtbetrag 72,09 €",
		"## Page 1\n\nFahrkarte Hamburg Hbf – Berlin Hbf",
	])
})
