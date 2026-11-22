import ApplicationBindings
import ApplicationPresentation
import Foundation

/// Owns the current `DocumentListingSnapshot`, caches row windows, and converts listing headings
/// using `DocumentFormatting`.
final class DocumentListModel {
	/// How the document list table should apply a newly fetched `DocumentListingReply`.
	enum Update {
		case reload
		case difference(removed: IndexSet, inserted: IndexSet, revised: IndexSet)
	}

	private struct CachedWindow {
		let firstRow: Int
		let rows: [ListingRow]
	}

	private static let windowSize = 64
	private static let maximumCachedWindows = 4

	private(set) var listing: (any DocumentListingSnapshot)?
	private(set) var rowCount = 0
	private(set) var documentCount = 0
	private var headingPositions = IndexSet()
	private var cachedWindows: [CachedWindow] = []

	func adopt(
		_ reply: DocumentListingReply,
		preceding: (any DocumentListingSnapshot)?
	) -> Update {
		let previousListing = listing
		listing = reply.listing
		rowCount = Int(reply.listing.rowCount())
		documentCount = Int(reply.listing.documentCount())
		headingPositions = IndexSet(reply.listing.headingPositions().map(Int.init))
		cachedWindows = []

		guard
			let previousListing,
			let preceding,
			previousListing === preceding,
			let difference = reply.difference
		else {
			return .reload
		}

		return .difference(
			removed: IndexSet(difference.removedPositions.map(Int.init)),
			inserted: IndexSet(difference.insertedPositions.map(Int.init)),
			revised: IndexSet(difference.revisedPositions.map(Int.init))
		)
	}

	func isHeading(at index: Int) -> Bool {
		headingPositions.contains(index)
	}

	func position(of document: DocumentIdentifier) -> Int? {
		listing?.positionOf(document: document).map(Int.init)
	}

	func documentIdentifier(at index: Int) -> DocumentIdentifier? {
		guard case let .document(documentRow) = row(at: index) else {
			return nil
		}
		return documentRow.document
	}

	/// Returns the row at `index` from a bounded window LRU cache, loading an aligned 64-row page when absent.
	func row(at index: Int) -> ListingRow? {
		guard let listing, index >= 0, index < rowCount else {
			return nil
		}

		let windowStart = (index / Self.windowSize) * Self.windowSize
		if let cachePosition = cachedWindows.firstIndex(where: { $0.firstRow == windowStart }) {
			let window = cachedWindows.remove(at: cachePosition)
			cachedWindows.append(window)
			let offset = index - window.firstRow
			return offset < window.rows.count ? window.rows[offset] : nil
		}

		let windowCount = min(Self.windowSize, rowCount - windowStart)
		let rows = listing.rows(first: UInt32(windowStart), count: UInt32(windowCount))
		cachedWindows.append(CachedWindow(firstRow: windowStart, rows: rows))
		if cachedWindows.count > Self.maximumCachedWindows {
			cachedWindows.removeFirst()
		}

		let offset = index - windowStart
		return offset < rows.count ? rows[offset] : nil
	}
}
