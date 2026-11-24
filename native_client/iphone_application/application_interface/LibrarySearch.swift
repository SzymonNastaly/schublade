import ApplicationBindings
import LibraryPresentation
import UIKit

/// A scope the list offers above the results while the typed text begins its name.
struct ScopeSuggestion: Equatable {
	let scope: NamedScope
	/// "Category", "Tag", or "Person".
	let kind: String
	let documents: UInt64

	var symbol: String {
		LibraryScopeMenu.symbol(of: scope.scope)
	}
}

extension String {
	/// Whether a person typed nothing but spaces, which searches for nothing.
	var isBlank: Bool {
		trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}
}

extension NamedScope {
	static let allDocuments = NamedScope(scope: .allDocuments, name: "All Documents")
}

/// The library's search field: the chosen scope as a token while a person searches, the scopes
/// whose names begin with the typed text, which the list offers above the results, and the words of
/// an excerpt that matched.
final class LibrarySearch: NSObject {
	static let maximumSuggestions = 3

	private weak var screen: LibraryViewController?
	/// The scope this field shows as its token, so a token the person deleted is told apart from
	/// one the field took away itself.
	private var tokenScope: LibraryScope?

	init(screen: LibraryViewController) {
		self.screen = screen
	}

	/// The token of the chosen scope while the search is active and the scope is not everything.
	func showToken(in searchController: UISearchController, scope: NamedScope) {
		let shown: LibraryScope? = searchController.isActive && scope.scope != .allDocuments ? scope.scope : nil
		guard shown != tokenScope else {
			return
		}
		tokenScope = shown
		let field = searchController.searchBar.searchTextField
		guard shown != nil else {
			field.tokens = []
			return
		}
		let token = UISearchToken(icon: UIImage(systemName: LibraryScopeMenu.symbol(of: scope.scope)), text: scope.name)
		field.tokens = [token]
	}

	/// The category, tag, and person names that begin with `text`, or one of its words does,
	/// ignoring case and diacritics. Senders are not among the facets, so none is offered.
	static func suggestions(for text: String, facets: LibraryFacets?, chosen: LibraryScope) -> [ScopeSuggestion] {
		let typed = fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
		guard !typed.isEmpty, let facets else {
			return []
		}
		let kinds: [(counts: [ScopeCount], kind: String)] = [
			(facets.categories, "Category"),
			(facets.tags, "Tag"),
			(facets.members, "Person"),
		]
		let offered = kinds.flatMap { counts, kind in
			counts.filter { count in
				count.scope.scope != chosen && begins(count.scope.name, with: typed)
			}.map { count in
				ScopeSuggestion(scope: count.scope, kind: kind, documents: count.documents)
			}
		}
		return Array(offered.prefix(maximumSuggestions))
	}

	/// The excerpt in the third line's colour, with what matched in the label's colour at semibold.
	static func markedExcerpt(_ excerpt: String, searchText: String) -> NSAttributedString {
		let font = UIFont.preferredFont(forTextStyle: .footnote)
		let marked = NSMutableAttributedString(
			string: excerpt,
			attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]
		)
		let semibold = UIFontMetrics(forTextStyle: .footnote)
			.scaledFont(for: .systemFont(ofSize: UIFont.preferredFont(
				forTextStyle: .footnote,
				compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
			).pointSize, weight: .semibold))
		for range in SearchTextMarking.matchedRanges(in: excerpt, searchText: searchText) {
			marked.addAttributes([.font: semibold, .foregroundColor: UIColor.label], range: NSRange(range, in: excerpt))
		}
		return marked
	}

	private static func fold(_ text: String) -> String {
		text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
	}

	private static func begins(_ name: String, with typed: String) -> Bool {
		let folded = fold(name)
		return folded.hasPrefix(typed)
			|| folded.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).contains { $0.hasPrefix(typed) }
	}
}

extension LibrarySearch: UISearchResultsUpdating, UISearchControllerDelegate {
	func updateSearchResults(for searchController: UISearchController) {
		guard let screen else {
			return
		}
		// The person deleted the token, which shows everything again.
		if tokenScope != nil, searchController.searchBar.searchTextField.tokens.isEmpty {
			tokenScope = nil
			screen.choose(.allDocuments)
		}
		screen.searchTextChanged(searchController.searchBar.text ?? "")
	}

	/// Before iOS 26 the toolbar gives way to the keyboard. From iOS 26 the search field is in it.
	func willPresentSearchController(_: UISearchController) {
		if #unavailable(iOS 26) {
			screen?.navigationController?.setToolbarHidden(true, animated: true)
		}
	}

	func didPresentSearchController(_ searchController: UISearchController) {
		if let scope = screen?.chosenScope {
			showToken(in: searchController, scope: scope)
		}
	}

	func willDismissSearchController(_ searchController: UISearchController) {
		tokenScope = nil
		searchController.searchBar.searchTextField.tokens = []
		if #unavailable(iOS 26) {
			screen?.navigationController?.setToolbarHidden(false, animated: true)
		}
	}
}
