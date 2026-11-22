import ApplicationBindings
import ApplicationInterface

/// Static document listing backing offscreen `InterfaceRenderer` screens without touching SQLite.
final class FixedDocumentListing: DocumentListingSnapshot {
	private let storedRows: [ListingRow]
	private let storedHeadings: [UInt32]
	private let storedDocumentCount: UInt32
	private let revision: UInt64

	init(rows: [ListingRow], contentRevision: UInt64 = 1) {
		storedRows = rows
		revision = contentRevision
		var headings: [UInt32] = []
		var documents: UInt32 = 0
		for (index, row) in rows.enumerated() {
			switch row {
			case .heading:
				headings.append(UInt32(index))
			case .document:
				documents += 1
			}
		}
		storedHeadings = headings
		storedDocumentCount = documents
	}

	func rowCount() -> UInt32 {
		UInt32(storedRows.count)
	}

	func documentCount() -> UInt32 {
		storedDocumentCount
	}

	func headingPositions() -> [UInt32] {
		storedHeadings
	}

	func contentRevision() -> UInt64 {
		revision
	}

	func rows(first: UInt32, count: UInt32) -> [ListingRow] {
		let start = min(Int(first), storedRows.count)
		let end = min(start + Int(count), storedRows.count)
		return Array(storedRows[start ..< end])
	}

	func positionOf(document: DocumentIdentifier) -> UInt32? {
		for (index, row) in storedRows.enumerated() {
			if case let .document(entry) = row, entry.document == document {
				return UInt32(index)
			}
		}
		return nil
	}
}
