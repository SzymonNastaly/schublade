import { describe, expect, test } from "vitest"
import expectedExtraction from "../../test_fixtures/documents/expected_extraction.json"
import digitalStatement from "../../test_fixtures/documents/bank_statement_digital.pdf"
import scannedAssessment from "../../test_fixtures/documents/income_tax_assessment_scanned.pdf"
import telecommunicationInvoice from "../../test_fixtures/documents/telecommunication_invoice_digital.pdf"
import { inspectPages, rasterizePage } from "./page_rasterizer"

function expectationFor(fileName: string) {
	const document = expectedExtraction.documents.find((candidate) => candidate.file_name === fileName)
	if (!document) throw new Error(`expected_extraction.json does not describe ${fileName}`)
	return { pageCount: document.page_count, hasTextLayer: document.has_text_layer }
}

async function inspectionSummary(pdfBytes: ArrayBuffer) {
	const pages = await inspectPages(new Uint8Array(pdfBytes))
	return { pageCount: pages.length, hasTextLayer: pages.every((page) => page.textCharacterCount > 0) }
}

describe("inspectPages", () => {
	test("reports the pages and the text layer of a digital PDF", async () => {
		expect(await inspectionSummary(digitalStatement)).toEqual(expectationFor("bank_statement_digital.pdf"))
		expect(expectationFor("bank_statement_digital.pdf")).toEqual({ pageCount: 2, hasTextLayer: true })
	})

	test("reports the pages of a scanned PDF and the absence of a text layer", async () => {
		expect(await inspectionSummary(scannedAssessment)).toEqual(expectationFor("income_tax_assessment_scanned.pdf"))
		expect(expectationFor("income_tax_assessment_scanned.pdf")).toEqual({ pageCount: 2, hasTextLayer: false })
	})

	test("extracts the text of each page", async () => {
		const pages = await inspectPages(new Uint8Array(telecommunicationInvoice))
		expect(
			pages.map((page) =>
				page.text.split("\n").filter((line) => /NK-2026-1048-3391|DE28 9302 4580 0418 8200 37/.test(line)),
			),
		).toEqual([
			[
				"Rechnungsnummer NK-2026-1048-3391",
				"Rechnungsnummer NK-2026-1048-3391 auf das folgende Konto:",
				"IBAN DE28 9302 4580 0418 8200 37",
				"IBAN DE28 9302 4580 0418 8200 37",
			],
		])
	})
})

describe("rasterizePage", () => {
	test("renders an A4 page to a grayscale PNG at 150 dots per inch", async () => {
		const page = await rasterizePage(new Uint8Array(scannedAssessment), 1)
		const header = new DataView(page.pngBytes.buffer, page.pngBytes.byteOffset, 26)
		expect({
			pageIndex: page.pageIndex,
			widthPixels: page.widthPixels,
			heightPixels: page.heightPixels,
			signature: [...page.pngBytes.subarray(0, 8)],
			encodedWidth: header.getUint32(16),
			encodedHeight: header.getUint32(20),
			colorType: header.getUint8(25),
		}).toEqual({
			pageIndex: 1,
			widthPixels: 1240,
			heightPixels: 1754,
			signature: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
			encodedWidth: 1240,
			encodedHeight: 1754,
			colorType: 0,
		})
	})
})
