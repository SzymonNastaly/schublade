import ApplicationBindings
import Foundation

/// What a person currently views in the window: the selected destination, search, order, document,
/// reader tab, inspector visibility, and any token replacement in progress.
public struct LibraryNavigationState: Equatable, Sendable {
	public var destination: NavigationDestination
	public var previousDestination: NavigationDestination?
	public var searchText: String
	public var browseOrder: ListingOrder
	public var selectedDocument: DocumentIdentifier?
	public var readerTab: ReaderTab
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
		guard case let .library(scope, _) = destination else {
			return nil
		}
		let query = trimmedSearchText
		if !query.isEmpty {
			return .search(scope: scope, text: query)
		}
		let effectiveOrder: ListingOrder = scope == .recentlyAdded ? .addition : browseOrder
		return .browse(scope: scope, order: effectiveOrder)
	}

	public var searchTerms: [String] {
		trimmedSearchText
			.split(whereSeparator: { $0.isWhitespace })
			.map(String.init)
	}
}
