import ApplicationBindings
import ApplicationInterface

/// Fixed in-memory `LibraryQueries` serving one scene's listing, documents, thumbnails, and
/// refusals for `InterfaceRenderer`. It counts the calls it answers, so a capture can wait until
/// the screens stopped asking.
final class RendererLibraryQueries: LibraryQueries {
	private let facetsResult: LibraryFacets
	private let detailsByDocument: [DocumentIdentifier: DocumentDetail]
	private let thumbnailPaths: [DocumentIdentifier: String]
	private let originalPaths: [DocumentIdentifier: String]
	private let extractedTexts: [DocumentIdentifier: String]
	private let listing: FixedDocumentListing
	private let originalRefusal: RepresentationRefusal?
	private(set) var callsStarted = 0
	private(set) var callsInFlight = 0

	init(
		facetsResult: LibraryFacets,
		detailsByDocument: [DocumentIdentifier: DocumentDetail],
		thumbnailPaths: [DocumentIdentifier: String],
		originalPaths: [DocumentIdentifier: String],
		extractedTexts: [DocumentIdentifier: String],
		listing: FixedDocumentListing = FixedDocumentListing(rows: []),
		originalRefusal: RepresentationRefusal? = nil
	) {
		self.facetsResult = facetsResult
		self.detailsByDocument = detailsByDocument
		self.thumbnailPaths = thumbnailPaths
		self.originalPaths = originalPaths
		self.extractedTexts = extractedTexts
		self.listing = listing
		self.originalRefusal = originalRefusal
	}

	/// The same documents, answering the scene's listing, refusing originals as given, and with any
	/// detail the scene replaces.
	func scene(
		listing: FixedDocumentListing,
		originalRefusal: RepresentationRefusal? = nil,
		replacingDetails replacements: [DocumentIdentifier: DocumentDetail] = [:]
	) -> RendererLibraryQueries {
		RendererLibraryQueries(
			facetsResult: facetsResult,
			detailsByDocument: detailsByDocument.merging(replacements) { _, replacement in replacement },
			thumbnailPaths: thumbnailPaths,
			originalPaths: originalPaths,
			extractedTexts: extractedTexts,
			listing: listing,
			originalRefusal: originalRefusal
		)
	}

	func listDocuments(
		request _: ListingRequest,
		preceding _: (any DocumentListingSnapshot)?
	) async throws(ApplicationFault) -> DocumentListingReply {
		await answer()
		return DocumentListingReply(listing: listing, difference: nil)
	}

	func facets() async throws(ApplicationFault) -> LibraryFacets {
		await answer()
		return facetsResult
	}

	func document(_ document: DocumentIdentifier) async throws(ApplicationFault) -> DocumentDetail? {
		await answer()
		return detailsByDocument[document]
	}

	func original(_ document: DocumentIdentifier) async throws(RepresentationRefusal) -> LocalFile {
		await answer()
		if let originalRefusal {
			throw originalRefusal
		}
		guard let path = originalPaths[document] else {
			throw .DocumentUnknown
		}
		return LocalFile(path: path)
	}

	func thumbnail(_ document: DocumentIdentifier) async throws(RepresentationRefusal) -> LocalFile? {
		await answer()
		return thumbnailPaths[document].map { LocalFile(path: $0) }
	}

	func extractedText(_ document: DocumentIdentifier) async throws(RepresentationRefusal) -> String {
		await answer()
		guard let text = extractedTexts[document] else {
			throw .NotAvailableYet
		}
		return text
	}

	func synchronize() {}

	/// The number of documents the scene's listing shows, for the painted subtitle.
	var shownDocuments: UInt32 {
		listing.documentCount()
	}

	/// The number of rows of the scene's listing, headings included.
	var shownRows: UInt32 {
		listing.rowCount()
	}

	/// Answers after one turn of the main actor, as a real query does, and counts the call.
	private func answer() async {
		callsStarted += 1
		callsInFlight += 1
		await Task.yield()
		callsInFlight -= 1
	}
}
