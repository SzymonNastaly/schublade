import { readFile } from "node:fs/promises"
import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs"
import { expect, test } from "vitest"
import { composeSubmission, readPageTexts } from "./document_reading"

const fixture = (path: string) => new URL(`../../test_fixtures/${path}`, import.meta.url)

test("PDF.js reads the text layer of a digital invoice with its printed values", async () => {
	const data = new Uint8Array(await readFile(fixture("documents/telecommunication_invoice_digital.pdf")))
	const pdf = await getDocument({ data }).promise

	const pageTexts = await readPageTexts(pdf)

	expect(pageTexts).toHaveLength(1)
	for (const printed of ["NK-2026-1048-3391", "DE28 9302 4580 0418 8200 37", "67,13 €", "20.10.2026"]) {
		expect(pageTexts[0]).toContain(printed)
	}
})

test("the body of a submission is the shared text, then the thumbnail, then the original, with their counts", async () => {
	const sharedText = await readFile(fixture("client_protocol/submitted_document_text.md"))
	const thumbnail = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0xff, 0xd9])
	const original = new TextEncoder().encode("%PDF-1.4 a letter")

	const submission = composeSubmission(new Blob([original]), "0".repeat(64), {
		pageTexts: [
			"Stadtwerke Talbrück GmbH\nJahresabrechnung Strom 2025-2026\nRechnungsnummer JA-2026-0381547\n",
			" \n",
			"Nachzahlungsbetrag 72,09 €\nFällig am 06.10.2026",
		],
		thumbnail: new Blob([thumbnail]),
	})

	expect({ ...submission, body: new Uint8Array(await submission.body.arrayBuffer()) }).toEqual({
		path: `/api/submitted_documents/${"0".repeat(64)}`,
		headers: {
			"Schublade-Text-Byte-Count": String(sharedText.byteLength),
			"Schublade-Thumbnail-Byte-Count": "6",
			"Schublade-Page-Count": "3",
		},
		body: new Uint8Array([...sharedText, ...thumbnail, ...original]),
	})
})
