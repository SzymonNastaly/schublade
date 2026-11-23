import ApplicationBindings
import ApplicationPresentation
import Foundation
import LibraryPresentation

/// Builds deterministic domain fixtures, cached PNG thumbnails, and scenarios for `InterfaceRenderer`.
final class RendererFixtures {
	let context: ApplicationWordingContext
	let queries: RendererLibraryQueries
	let sampleListing: FixedDocumentListing
	let searchListing: FixedDocumentListing
	let emptyListing = FixedDocumentListing(rows: [])
	let invoiceIdentifier = DocumentIdentifier(value: "doc-electricity-invoice")
	let receiptIdentifier = DocumentIdentifier(value: "doc-supermarket-receipt")
	let invoiceDetail: DocumentDetail
	let electricityPdfPath: String
	let receiptImagePath: String
	let invoiceText: String
	let facets = RendererSampleCatalog.sampleFacets

	init(fixturesDirectory: URL, temporaryDirectory: URL) {
		context = Self.fixedContext()
		let pdfURL = fixturesDirectory.appending(path: "electricity_invoice_scanned.pdf")
		let imageURL = fixturesDirectory.appending(path: "supermarket_receipt_photograph.jpg")
		electricityPdfPath = pdfURL.path(percentEncoded: false)
		receiptImagePath = imageURL.path(percentEncoded: false)

		invoiceDetail = RendererSampleCatalog.makeInvoiceDetail(document: invoiceIdentifier)
		let receiptDetail = RendererSampleCatalog.makeReceiptDetail(document: receiptIdentifier)

		invoiceText = Self.sampleInvoiceText
		queries = RendererLibraryQueries(
			facetsResult: RendererSampleCatalog.sampleFacets,
			detailsByDocument: [
				invoiceIdentifier: invoiceDetail,
				receiptIdentifier: receiptDetail,
			],
			thumbnailPaths: RendererSampleCatalog.generateThumbnails(
				temporaryDirectory: temporaryDirectory,
				invoiceIdentifier: invoiceIdentifier,
				pdfPath: electricityPdfPath,
				receiptIdentifier: receiptIdentifier,
				imagePath: receiptImagePath
			),
			originalPaths: [
				invoiceIdentifier: electricityPdfPath,
				receiptIdentifier: receiptImagePath,
			],
			extractedTexts: [
				invoiceIdentifier: invoiceText,
			]
		)
		sampleListing = FixedDocumentListing(
			rows: RendererSampleCatalog.makeSampleRows(
				invoiceId: invoiceIdentifier,
				receiptId: receiptIdentifier
			),
			contentRevision: 12
		)
		searchListing = FixedDocumentListing(
			rows: RendererSampleCatalog.makeSearchRows(
				invoiceId: invoiceIdentifier,
				receiptId: receiptIdentifier
			),
			contentRevision: 12
		)
	}

	/// A fixed clock, calendar, and locale, so every rendering shows the same words.
	private static func fixedContext() -> ApplicationWordingContext {
		var calendar = Calendar(identifier: .gregorian)
		if let utc = TimeZone(secondsFromGMT: 0) {
			calendar.timeZone = utc
		}
		return ApplicationWordingContext(
			library: WordingContext(
				now: Date(timeIntervalSince1970: 1_790_000_000),
				calendar: calendar,
				locale: Locale(identifier: "en_GB")
			),
			folderName: { URL(fileURLWithPath: $0).lastPathComponent }
		)
	}

	private static let sampleInvoiceText = """
	# Stadtwerke Talbrück GmbH — Jahresabrechnung Strom 2026

	Rechnungsnummer: RE-2026-44109
	Vertragskonto: 88120419
	Zahlungsbetrag: 1,234.50 EUR (fällig am 06.10.2026)
	IBAN: DE89 3704 0044 0532 0130 00

	Sehr geehrter Herr Becker,

	vielen Dank für Ihre Treue. Die Haftpflichtversicherung und Abschlagszahlung wurden verrechnet.
	"""

	func makeStatuses(
		condition: ConnectionCondition = .connected,
		collector: CollectorStatus? = RendererFixtures.makeCollectorStatus(),
		facets: LibraryFacets = RendererSampleCatalog.sampleFacets
	) -> ApplicationStatuses {
		let library = LibraryStatus(
			revision: 12,
			archive: .configured(
				origin: "https://archive.example.org",
				host: "archive.example.org",
				condition: condition,
				permission: collector == nil ? .readOnly : .readAndCollect,
				restricted: false
			),
			copy: .complete(synchronizedAt: context.library.now),
			contentRevision: 12,
			counts: LibraryCounts(
				documents: facets.documents,
				documentsInIngestion: facets.documentsInIngestion,
				documentsFailed: facets.documentsFailed,
				documentsAwaitingText: 308
			)
		)
		return ApplicationStatuses(library: library, collector: collector)
	}

	/// Downloads collecting, and Paperwork in the admission a scene shows.
	static func makeCollectorStatus(
		paperworkAdmission: FolderAdmission = .collecting,
		attention: [AttentionItem] = [],
		activities: [Activity] = [],
		receipts: [Receipt] = []
	) -> CollectorStatus {
		CollectorStatus(
			revision: 4,
			folders: [
				FolderStatus(folder: downloads, admission: .collecting, unavailability: nil),
				FolderStatus(folder: paperwork, admission: paperworkAdmission, unavailability: nil),
			],
			progress: CollectionProgress(
				documentsInArchive: 98,
				documentsAwaitingSubmission: 0,
				filesUnderExamination: 0
			),
			activities: activities,
			attention: attention,
			recentReceipts: receipts
		)
	}

	static let downloads = FolderReference(identifier: FolderIdentifier(value: 1), root: "/Users/owner/Downloads")
	static let paperwork = FolderReference(identifier: FolderIdentifier(value: 2), root: "/Users/owner/Paperwork")
}
