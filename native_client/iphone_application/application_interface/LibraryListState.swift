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

	/// The documents under their headings, none in any other state.
	var listedSections: [ListedSection] {
		if case let .documents(sections) = self {
			sections
		} else {
			[]
		}
	}

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

/// A connection that needs the person, above everything else in the list.
enum ConnectionAttention: Equatable {
	case tokenRefused
	case tokenLacksPermission
	case archiveOutdated

	static func resolve(_ archive: ArchiveConnection) -> ConnectionAttention? {
		switch archive {
		case .configured(_, _, .suspended(.credentialRefused), _, _): .tokenRefused
		case .configured(_, _, .suspended(.credentialInsufficient), _, _): .tokenLacksPermission
		case .configured(_, _, .archiveOutdated, _, _): .archiveOutdated
		default: nil
		}
	}

	var title: String {
		switch self {
		case .tokenRefused: "Token Refused"
		case .tokenLacksPermission: "Token Lacks Permission"
		case .archiveOutdated: "Archive Update Required"
		}
	}

	var detail: String {
		switch self {
		case .tokenRefused:
			"The archive no longer accepts this iPhone's token. Replace it to send and to read new documents."
		case .tokenLacksPermission:
			"This token can no longer read your archive. Replace it."
		case .archiveOutdated:
			"Update your archive, then open Schublade again."
		}
	}

	/// Whether a new token is the way out, which the row offers.
	var replacesToken: Bool {
		self != .archiveOutdated
	}
}

/// What the library's list shows.
struct LibraryListContent: Equatable {
	let attention: ConnectionAttention?
	let state: LibraryListState
	let arrivals: [Arrival]
	/// The text of a search, nil while a person browses.
	let searchText: String?
}

nonisolated enum LibrarySection: Hashable {
	case attention
	/// This iPhone's arrivals, then the listing's documents in ingestion that no arrival shows.
	case arriving
	case listed(ListingHeading?)
	case notice
}

nonisolated enum LibraryItem: Hashable {
	case attention
	case arrival(UUID)
	case document(DocumentIdentifier)
	case notice
}
