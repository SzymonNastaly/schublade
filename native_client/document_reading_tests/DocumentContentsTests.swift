import DocumentReading
import Foundation
import Testing

struct DocumentContentsTests {
	private static func fixture(_ name: String) throws -> Data {
		try Data(contentsOf: URL(filePath: #filePath)
			.deletingLastPathComponent()
			.appending(path: "../../test_fixtures/documents/\(name)"))
	}

	@Test func aDigitalPDFGivesItsTextLayerAndFirstPage() throws {
		let contents = try DocumentContents.read(Self.fixture("telecommunication_invoice_digital.pdf"), kind: .pdf)

		#expect(contents.pageTexts.count == 1)
		for printed in ["NK-2026-1048-3391", "67,13 €", "20.10.2026", "DE28 9302 4580 0418 8200 37"] {
			#expect(contents.pageTexts[0].contains(printed))
		}
	}

	@Test func aScannedPDFGivesWhatVisionRecognizes() throws {
		let contents = try DocumentContents.read(Self.fixture("dental_invoice_scanned.pdf"), kind: .pdf)

		#expect(contents.pageTexts.count == 1)
		for printed in ["ZA-2026-0193", "91,84 €", "26.09.2026", "DE80 9701 1320 0605 1900 31"] {
			#expect(contents.pageTexts[0].contains(printed))
		}
	}
}
