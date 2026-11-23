import ApplicationBindings
import Foundation
import LibraryPresentation

/// What the documents part of the library screen shows. One value drives the rows and the message
/// in their place, so a screen never shows a message over rows or rows under a stale message.
enum LibraryListState: Equatable {
	case awaitingListing
	/// The first copy of the archive fills and holds nothing of this request yet.
	case fillingCopy(StatusLinePresentation)
	case documents([ListedSection])
	/// The request found nothing: an empty scope, no match, or a fault of the library.
	case empty(EmptyListPresentation)
	/// The archive holds no document at all, which the iPhone words itself.
	case emptyArchive
	case failed(EmptyListPresentation)

	struct ListedSection: Equatable {
		let heading: ListingHeading?
		let rows: [DocumentRow]
	}

	enum ListingOutcome {
		case listed([ListingRow])
		case failed(ApplicationFault)
	}

	static func resolve(
		outcome: ListingOutcome?,
		status: LibraryStatus,
		scope: LibraryScope,
		searchText: String,
		context: WordingContext
	) -> LibraryListState {
		switch outcome {
		case nil:
			return .awaitingListing
		case let .failed(fault):
			return EmptyListPresentation.resolve(
				scope: scope,
				searchText: searchText,
				libraryStatus: status,
				libraryFault: nil,
				listingFault: LibraryFailureWording.faultSentence(fault)
			).map(LibraryListState.failed) ?? .emptyArchive
		case let .listed(rows):
			let sections = sections(of: rows)
			if !sections.isEmpty {
				return .documents(sections)
			}
			let searching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			if case .filling = status.copy, !searching {
				return .fillingCopy(StatusLinePresentation.resolve(
					library: status,
					fault: nil,
					uploadingFiles: 0,
					context: context
				))
			}
			return EmptyListPresentation.resolve(
				scope: scope,
				searchText: searchText,
				libraryStatus: status,
				libraryFault: nil,
				listingFault: nil
			).map(LibraryListState.empty) ?? .emptyArchive
		}
	}

	/// Groups the rows under their headings. A list of diffable items must not hold one twice, so a
	/// repeated heading or document joins the first one, which the copy's listing never produces.
	private static func sections(of rows: [ListingRow]) -> [ListedSection] {
		var headings: [ListingHeading?] = []
		var rowsByHeading: [ListingHeading?: [DocumentRow]] = [:]
		var current: ListingHeading?
		var listed: Set<DocumentIdentifier> = []
		for row in rows {
			switch row {
			case let .heading(heading):
				current = heading
			case let .document(document):
				guard listed.insert(document.document).inserted else {
					continue
				}
				if rowsByHeading[current] == nil {
					headings.append(current)
				}
				rowsByHeading[current, default: []].append(document)
			}
		}
		return headings.map { ListedSection(heading: $0, rows: rowsByHeading[$0] ?? []) }
	}
}

nonisolated enum LibrarySection: Hashable {
	/// This iPhone's arrivals, then the listing's documents in ingestion that no arrival shows.
	case arriving
	case listed(ListingHeading?)
	case notice
}

nonisolated enum LibraryItem: Hashable {
	case arrival(UUID)
	case document(DocumentIdentifier)
	case notice
}
