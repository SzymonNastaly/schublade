import AppKit
import ApplicationBindings

/// How the document list table should apply a newly fetched `ListingAnswer`.
enum DocumentListUpdate {
	case reload
	case difference(removed: IndexSet, inserted: IndexSet, revised: IndexSet)
}

/// Owns the current `DocumentListing`, caches row windows, and formats listing summary and
/// section-heading text for `DocumentListViewController`.
final class DocumentListModel {
	private static let windowSize = 64

	private static let utcCalendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		if let utc = TimeZone(secondsFromGMT: 0) {
			calendar.timeZone = utc
		}
		return calendar
	}()

	private static let periodFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.calendar = utcCalendar
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = utcCalendar.timeZone
		formatter.dateFormat = "LLLL yyyy"
		return formatter
	}()

	private(set) var listing: DocumentListing?
	private var cachedFirstRow = 0
	private var cachedRows: [ListingRow] = []

	var rowCount: Int {
		listing.map { Int($0.rowCount()) } ?? 0
	}

	var documentCount: Int {
		listing.map { Int($0.documentCount()) } ?? 0
	}

	/// Adopts `answer` and returns incremental table updates only when `answer` was diffed against the still-shown
	/// `preceding` listing.
	func adopt(_ answer: ListingAnswer, preceding: DocumentListing?) -> DocumentListUpdate {
		let previousListing = listing
		listing = answer.listing
		cachedFirstRow = 0
		cachedRows = []

		guard
			let previousListing,
			let preceding,
			previousListing === preceding,
			let difference = answer.difference
		else {
			return .reload
		}

		return .difference(
			removed: IndexSet(difference.removedPositions.map(Int.init)),
			inserted: IndexSet(difference.insertedPositions.map(Int.init)),
			revised: IndexSet(difference.revisedPositions.map(Int.init))
		)
	}

	/// Returns the row at `index` from the in-memory window cache, loading an aligned 64-row page when needed.
	func row(at index: Int) -> ListingRow? {
		guard let listing else {
			return nil
		}
		let total = Int(listing.rowCount())
		guard index >= 0, index < total else {
			return nil
		}

		if index < cachedFirstRow || index >= cachedFirstRow + cachedRows.count {
			let windowStart = (index / Self.windowSize) * Self.windowSize
			let windowCount = min(Self.windowSize, total - windowStart)
			cachedFirstRow = windowStart
			cachedRows = listing.rows(first: UInt32(windowStart), count: UInt32(windowCount))
		}

		let offset = index - cachedFirstRow
		guard offset >= 0, offset < cachedRows.count else {
			return nil
		}
		return cachedRows[offset]
	}

	static func summarySentence(documentCount: Int, status: LibraryStatus?) -> String {
		let countText = documentCount == 1 ? "1 document" : "\(documentCount) documents"
		guard let status else {
			return countText
		}
		let statusNote: String? = switch status.copy {
		case .absent:
			nil
		case let .filling(received, remaining):
			"Loading \(received) of \(received + remaining)"
		case .complete:
			archiveConditionNote(status.archive)
		}
		if let statusNote {
			return "\(countText) · \(statusNote)"
		}
		return countText
	}

	static func headingText(_ heading: ListingHeading) -> String {
		switch heading {
		case .arriving:
			return "Arriving"
		case let .period(year, month):
			let components = DateComponents(
				calendar: utcCalendar,
				timeZone: utcCalendar.timeZone,
				year: Int(year),
				month: Int(month),
				day: 1
			)
			if let date = utcCalendar.date(from: components) {
				return periodFormatter.string(from: date)
			}
			return String(format: "%04u-%02u", UInt(year), UInt(month))
		case .detailsMatched:
			return "Matches in Details"
		case .textMatched:
			return "Matches in Text"
		}
	}

	private static func archiveConditionNote(_ archive: ArchiveConnection) -> String? {
		switch archive {
		case .notConfigured:
			nil
		case let .configured(_, _, condition, _, _):
			switch condition {
			case .connected, .checking:
				nil
			case .unreachable:
				"Offline"
			case .deferred:
				"Archive busy"
			case .suspended(.credentialRefused):
				"Token refused"
			case .suspended(.credentialInsufficient):
				"Token lacks read permission"
			case .archiveOutdated:
				"Update required"
			}
		}
	}
}
