import ApplicationBindings
import Foundation
import LibraryPresentation

/// What a person currently views in the window: the selected destination, search, order, document,
/// reader tab, inspector visibility, and any token replacement in progress.
public struct LibraryNavigationState: Equatable, Sendable {
	public var destination: NavigationDestination
	public var previousDestination: NavigationDestination?
	public var searchText: String
	public var browseOrder: ListingOrder
	public var selectedDocument: DocumentIdentifier?
	/// The tab a person chose.
	public var readerTab: ReaderTab
	/// The document whose text the reader shows for a search's match that its original cannot mark.
	/// The reader turned to it by itself, so `readerTab` keeps the person's choice.
	public var textShownForMatch: DocumentIdentifier?
	public var inspectorVisible: Bool
	public var replacingTokenOrigin: String?

	public init(
		destination: NavigationDestination = .library(.allDocuments, title: nil),
		previousDestination: NavigationDestination? = nil,
		searchText: String = "",
		browseOrder: ListingOrder = .documentDate,
		selectedDocument: DocumentIdentifier? = nil,
		readerTab: ReaderTab = .original,
		inspectorVisible: Bool = true,
		replacingTokenOrigin: String? = nil
	) {
		self.destination = destination
		self.previousDestination = previousDestination
		self.searchText = searchText
		self.browseOrder = browseOrder
		self.selectedDocument = selectedDocument
		self.readerTab = readerTab
		self.inspectorVisible = inspectorVisible
		self.replacingTokenOrigin = replacingTokenOrigin
	}

	/// Takes a search's text. A page such as a folder or Needs Attention has no list to search, so a
	/// search typed there moves to All Documents.
	public mutating func search(_ text: String) {
		searchText = text
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return
		}
		switch destination {
		case .library:
			break
		case .needsAttention, .folder:
			destination = .library(.allDocuments, title: nil)
			selectedDocument = nil
		}
	}

	public var trimmedSearchText: String {
		searchText.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public var activeListingRequest: ListingRequest? {
		guard case let .library(scope, name) = destination else {
			return nil
		}
		return LibraryScopePresentation.resolve(
			scope: scope,
			name: name,
			searchText: searchText,
			browseOrder: browseOrder
		).request
	}

	/// The tab the reader shows: the person's, or the text of the selected document while the search
	/// matched only its text.
	public var shownReaderTab: ReaderTab {
		if let textShownForMatch, textShownForMatch == selectedDocument, !searchTerms.isEmpty {
			return .text
		}
		return readerTab
	}

	public var searchTerms: [String] {
		trimmedSearchText
			.split(whereSeparator: { $0.isWhitespace })
			.map(String.init)
	}
}
