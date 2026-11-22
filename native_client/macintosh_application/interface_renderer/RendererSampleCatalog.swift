import AppKit
import ApplicationBindings
import ApplicationPresentation
import PDFKit

/// Sample facets, documents, rows, and rendered thumbnail helpers shared by `RendererFixtures`.
enum RendererSampleCatalog {
	static let senderStadtwerke = NamedScope(
		scope: .sender(sender: SenderIdentifier(value: "s1")),
		name: "Stadtwerke Talbrück GmbH"
	)
	static let senderFrischemarkt = NamedScope(
		scope: .sender(sender: SenderIdentifier(value: "s2")),
		name: "Frischemarkt"
	)
	static let categoryInvoice = NamedScope(
		scope: .category(category: CategoryIdentifier(value: "c1")),
		name: "Invoice"
	)
	static let categoryReceipt = NamedScope(
		scope: .category(category: CategoryIdentifier(value: "c2")),
		name: "Receipt"
	)
	static let tagStrom = NamedScope(scope: .tag(tag: TagIdentifier(value: "t1")), name: "strom")
	static let tagHousehold = NamedScope(scope: .tag(tag: TagIdentifier(value: "t2")), name: "haushalt-2026")
	static let tagTax = NamedScope(scope: .tag(tag: TagIdentifier(value: "t3")), name: "tax-2026")

	static let sampleFacets = LibraryFacets(
		contentRevision: 12,
		documents: 1508,
		documentsInIngestion: 1,
		documentsFailed: 0,
		householdDocuments: 611,
		members: [
			ScopeCount(
				scope: NamedScope(scope: .member(member: MemberIdentifier(value: "m1")), name: "Jonas Becker"),
				documents: 402
			),
		],
		categories: [
			ScopeCount(scope: categoryInvoice, documents: 412),
			ScopeCount(scope: categoryReceipt, documents: 289),
		],
		tags: [
			ScopeCount(scope: tagStrom, documents: 38),
			ScopeCount(scope: tagTax, documents: 24),
		]
	)

	static let emptyFacets = LibraryFacets(
		contentRevision: 1,
		documents: 0,
		documentsInIngestion: 0,
		documentsFailed: 0,
		householdDocuments: 0,
		members: [],
		categories: [],
		tags: []
	)

	static func makeInvoiceDetail(document: DocumentIdentifier) -> DocumentDetail {
		DocumentDetail(
			document: document,
			condition: .archived,
			title: "Electricity Annual Statement 2026",
			documentDate: CalendarDate(year: 2026, month: 9, day: 22),
			sender: senderStadtwerke,
			category: categoryInvoice,
			person: .household,
			tags: [tagStrom, tagHousehold, tagTax],
			summary: "Annual electricity statement for 2026 showing remaining balance due by October 6.",
			fields: [
				DetailField(key: "amount", value: .number(decimalText: "1234.5")),
				DetailField(key: "currency", value: .text(text: "EUR")),
				DetailField(key: "due_date", value: .date(date: CalendarDate(year: 2026, month: 10, day: 6))),
				DetailField(key: "iban", value: .text(text: "DE89370400440532013000")),
				DetailField(key: "invoice_number", value: .text(text: "RE-2026-44109")),
			],
			originalKind: .portableDocument,
			byteSize: 190_941,
			pageCount: 2,
			arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
			archivePage: "https://archive.example.org/documents/doc-electricity-invoice",
			suggestedFileName: "2026-09-22 Stadtwerke Talbrück Electricity Annual Statement 2026.pdf"
		)
	}

	static func makeReceiptDetail(document: DocumentIdentifier) -> DocumentDetail {
		DocumentDetail(
			document: document,
			condition: .archived,
			title: "Supermarket Receipt",
			documentDate: CalendarDate(year: 2026, month: 9, day: 18),
			sender: senderFrischemarkt,
			category: categoryReceipt,
			person: .household,
			tags: [tagHousehold],
			summary: "Groceries paid by card.",
			fields: [
				DetailField(key: "amount", value: .number(decimalText: "48.75")),
				DetailField(key: "currency", value: .text(text: "EUR")),
			],
			originalKind: .jpegImage,
			byteSize: 253_289,
			pageCount: 1,
			arrivedAt: Date(timeIntervalSince1970: 1_789_800_000),
			archivePage: "https://archive.example.org/documents/doc-supermarket-receipt",
			suggestedFileName: "2026-09-18 Frischemarkt Supermarket Receipt.jpg"
		)
	}

	static func makeSampleRows(invoiceId: DocumentIdentifier, receiptId: DocumentIdentifier) -> [ListingRow] {
		[
			.heading(heading: .arriving),
			.document(row: DocumentRow(
				document: DocumentIdentifier(value: "doc-arriving"),
				condition: .inIngestion(stage: .classifying),
				title: "Meldebescheinigung.pdf",
				senderName: nil,
				documentDate: nil,
				arrivedAt: Date(timeIntervalSince1970: 1_790_000_100),
				amount: nil,
				passage: nil,
				contentKnown: false,
				suggestedFileName: "document.pdf"
			)),
			.heading(heading: .period(year: 2026, month: 9)),
			.document(row: DocumentRow(
				document: invoiceId,
				condition: .archived,
				title: "Electricity Annual Statement 2026",
				senderName: "Stadtwerke Talbrück GmbH",
				documentDate: CalendarDate(year: 2026, month: 9, day: 22),
				arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
				amount: Amount(decimalText: "1234.5", currency: "EUR"),
				passage: .summary(text: "Annual electricity statement for 2026 showing remaining balance due."),
				contentKnown: true,
				suggestedFileName: "document.pdf"
			)),
			.document(row: DocumentRow(
				document: receiptId,
				condition: .archived,
				title: "Supermarket Receipt",
				senderName: "Frischemarkt",
				documentDate: CalendarDate(year: 2026, month: 9, day: 18),
				arrivedAt: Date(timeIntervalSince1970: 1_789_800_000),
				amount: Amount(decimalText: "48.75", currency: "EUR"),
				passage: .summary(text: "Weekly grocery receipt."),
				contentKnown: true,
				suggestedFileName: "document.pdf"
			)),
		]
	}

	static func makeSearchRows(invoiceId: DocumentIdentifier, receiptId: DocumentIdentifier) -> [ListingRow] {
		[
			.heading(heading: .detailsMatched),
			.document(row: DocumentRow(
				document: receiptId,
				condition: .archived,
				title: "Supermarket Receipt",
				senderName: "Frischemarkt",
				documentDate: CalendarDate(year: 2026, month: 9, day: 18),
				arrivedAt: Date(timeIntervalSince1970: 1_789_800_000),
				amount: Amount(decimalText: "48.75", currency: "EUR"),
				passage: .summary(text: "Weekly grocery receipt."),
				contentKnown: true,
				suggestedFileName: "document.pdf"
			)),
			.heading(heading: .textMatched),
			.document(row: DocumentRow(
				document: invoiceId,
				condition: .archived,
				title: "Electricity Annual Statement 2026",
				senderName: "Stadtwerke Talbrück GmbH",
				documentDate: CalendarDate(year: 2026, month: 9, day: 22),
				arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
				amount: Amount(decimalText: "1234.5", currency: "EUR"),
				passage: .excerpt(text: "…die Haftpflichtversicherung und Abschlagszahlung wurden verrechnet."),
				contentKnown: true,
				suggestedFileName: "document.pdf"
			)),
		]
	}

	static func generateThumbnails(
		temporaryDirectory: URL,
		invoiceIdentifier: DocumentIdentifier,
		pdfPath: String,
		receiptIdentifier: DocumentIdentifier,
		imagePath: String
	) -> [DocumentIdentifier: String] {
		var paths = [receiptIdentifier: imagePath]
		let page = PDFDocument(url: URL(fileURLWithPath: pdfPath))?.page(at: 0)
		guard let page else {
			return paths
		}
		let image = page.thumbnail(of: NSSize(width: 120, height: 156), for: .mediaBox)
		let target = temporaryDirectory.appending(path: "invoice_thumb.png")
		guard let png = image.tiffRepresentation
			.flatMap(NSBitmapImageRep.init(data:))?
			.representation(using: .png, properties: [:])
		else {
			return paths
		}
		try? png.write(to: target)
		paths[invoiceIdentifier] = target.path(percentEncoded: false)
		return paths
	}
}
