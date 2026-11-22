import AppKit
import ApplicationBindings

/// Owns the current `DocumentListing`, caches row windows, and formats listing summary and
/// section-heading text for `DocumentListViewController`.
final class DocumentListModel {
	/// How the document list table should apply a newly fetched `ListingAnswer`.
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

	private static let gregorianCalendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		if let universalTimeZone = TimeZone(secondsFromGMT: 0) {
			calendar.timeZone = universalTimeZone
		}
		return calendar
	}()

	private static let periodFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.calendar = gregorianCalendar
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = gregorianCalendar.timeZone
		formatter.dateFormat = "LLLL yyyy"
		return formatter
	}()

	private(set) var listing: DocumentListing?
	private(set) var rowCount = 0
	private(set) var documentCount = 0
	private var headingPositions = IndexSet()
	private var cachedWindows: [CachedWindow] = []

	/// Adopts `answer` and returns incremental table updates only when `answer` was diffed against the still-shown
	/// `preceding` listing.
	func adopt(_ answer: ListingAnswer, preceding: DocumentListing?) -> Update {
		let previousListing = listing
		listing = answer.listing
		rowCount = Int(answer.listing.rowCount())
		documentCount = Int(answer.listing.documentCount())
		headingPositions = IndexSet(answer.listing.headingPositions().map(Int.init))
		cachedWindows = []

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

	func isHeading(at index: Int) -> Bool {
		headingPositions.contains(index)
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

	static func summarySentence(
		documentCount: Int,
		status: LibraryStatus?,
		libraryFault: ApplicationFault?,
		listingFault: String?
	) -> String {
		let countText = documentCount == 1 ? "1 document" : "\(documentCount) documents"
		if let listingFault {
			return "\(countText) · \(listingFault)"
		}
		if let libraryFault {
			return "\(countText) · \(ApplicationFailureWording.faultSentence(libraryFault))"
		}
		guard let status else {
			return countText
		}
		switch status.copy {
		case .absent:
			return countText
		case let .filling(received, _):
			if received == 0 {
				return "Loading…"
			}
			let receivedText = received == 1 ? "1 document" : "\(received) documents"
			return "Loading, \(receivedText) so far"
		case .complete:
			if let statusNote = archiveConditionNote(status.archive) {
				return "\(countText) · \(statusNote)"
			}
			return countText
		}
	}

	static func headingText(_ heading: ListingHeading) -> String {
		switch heading {
		case .arriving:
			return "Arriving"
		case let .period(year, month):
			let components = DateComponents(
				calendar: gregorianCalendar,
				timeZone: gregorianCalendar.timeZone,
				year: Int(year),
				month: Int(month),
				day: 1
			)
			if let date = gregorianCalendar.date(from: components) {
				return periodFormatter.string(from: date)
			}
			return String(format: "%04u-%02u", UInt32(year), UInt32(month))
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
