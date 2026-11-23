import ApplicationBindings
import Foundation

/// What a listing of one scope shows around its rows: its title, the request that reads it, and the
/// order and search it offers.
public struct LibraryScopePresentation: Equatable, Sendable {
	public let title: String
	public let request: ListingRequest
	public let effectiveOrder: ListingOrder
	public let allowsSortSelection: Bool
	public let searchAllDocumentsAvailable: Bool

	public init(
		title: String,
		request: ListingRequest,
		effectiveOrder: ListingOrder,
		allowsSortSelection: Bool,
		searchAllDocumentsAvailable: Bool
	) {
		self.title = title
		self.request = request
		self.effectiveOrder = effectiveOrder
		self.allowsSortSelection = allowsSortSelection
		self.searchAllDocumentsAvailable = searchAllDocumentsAvailable
	}

	/// `name` is the name a member, category, tag, or sender was chosen by.
	public static func resolve(
		scope: LibraryScope,
		name: String?,
		searchText: String,
		browseOrder: ListingOrder
	) -> LibraryScopePresentation {
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		let isSearching = !query.isEmpty
		let effectiveOrder: ListingOrder = scope == .recentlyAdded ? .addition : browseOrder
		return LibraryScopePresentation(
			title: scopeTitle(scope, name: name),
			request: isSearching
				? .search(scope: scope, text: query)
				: .browse(scope: scope, order: effectiveOrder),
			effectiveOrder: effectiveOrder,
			allowsSortSelection: !isSearching && scope != .recentlyAdded,
			searchAllDocumentsAvailable: isSearching && scope != .allDocuments
		)
	}

	/// While a search runs before the local copy holds every text, how many texts it searches.
	public static func textIndexingNotice(searchText: String, counts: LibraryCounts) -> String? {
		let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		guard isSearching, counts.documentsAwaitingText > 0, counts.documents > 0 else {
			return nil
		}
		let total = counts.documents
		let ready = total > counts.documentsAwaitingText ? total - counts.documentsAwaitingText : 0
		return "Searching the text of \(DocumentFormatting.groupedNumber(ready)) of "
			+ "\(DocumentFormatting.groupedNumber(total)) documents"
	}

	private static func scopeTitle(_ scope: LibraryScope, name: String?) -> String {
		switch scope {
		case .allDocuments:
			"All Documents"
		case .recentlyAdded:
			"Recently Added"
		case .inIngestion:
			"Arriving"
		case .failed:
			"Failed Documents"
		case .household:
			"Household"
		case .member, .category, .tag:
			name ?? "Schublade"
		case .sender:
			name ?? "Sender"
		}
	}
}
