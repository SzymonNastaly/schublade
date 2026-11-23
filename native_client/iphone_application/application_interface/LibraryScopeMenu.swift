import ApplicationBindings
import LibraryPresentation
import UIKit

/// The scopes a person can show, with their counts. "Arriving" is not among them, because the top
/// of All Documents shows the same documents, and Failed Documents shows only while there are any.
enum LibraryScopeMenu {
	/// The symbol of a scope, in this menu and in the search field's token.
	static func symbol(of scope: LibraryScope) -> String {
		switch scope {
		case .allDocuments: "tray.full"
		case .recentlyAdded: "clock"
		case .inIngestion: "arrow.down.circle"
		case .failed: "exclamationmark.triangle"
		case .household: "house"
		case .member: "person"
		case .category: "folder"
		case .tag: "tag"
		case .sender: "building.2"
		}
	}

	static func elements(
		facets: LibraryFacets?,
		chosen: LibraryScope,
		choose: @escaping (NamedScope) -> Void
	) -> [UIMenuElement] {
		func action(_ scope: LibraryScope, name: String? = nil, count: UInt64?) -> UIAction {
			let title = LibraryScopePresentation.resolve(
				scope: scope,
				name: name,
				searchText: "",
				browseOrder: .documentDate
			).title
			let action = UIAction(title: title, image: UIImage(systemName: symbol(of: scope))) { _ in
				choose(NamedScope(scope: scope, name: title))
			}
			action.subtitle = count.flatMap { $0 == 0 ? nil : DocumentFormatting.countText($0, singular: "document") }
			action.state = scope == chosen ? .on : .off
			return action
		}

		func submenu(_ title: String, symbol: String, _ counts: [ScopeCount]) -> UIMenu? {
			guard !counts.isEmpty else {
				return nil
			}
			let menu = UIMenu(title: title, image: UIImage(systemName: symbol), children: counts.map { count in
				action(count.scope.scope, name: count.scope.name, count: count.documents)
			})
			if counts.contains(where: { $0.scope.scope == chosen }) {
				menu.subtitle = counts.first { $0.scope.scope == chosen }?.scope.name
			}
			return menu
		}

		let failed = (facets?.documentsFailed ?? 0) > 0 || chosen == .failed
			? action(.failed, count: facets?.documentsFailed)
			: nil
		let library = UIMenu(options: .displayInline, children: [
			action(.allDocuments, count: facets?.documents),
			action(.recentlyAdded, count: nil),
			failed,
		].compactMap(\.self))
		let household: [UIMenuElement?] = [
			action(.household, count: facets?.householdDocuments),
			submenu("People", symbol: "person", facets?.members ?? []),
		]
		let filing: [UIMenuElement?] = [
			submenu("Categories", symbol: "folder", facets?.categories ?? []),
			submenu("Tags", symbol: "tag", facets?.tags ?? []),
		]
		let people = UIMenu(options: .displayInline, children: household.compactMap(\.self))
		let files = UIMenu(options: .displayInline, children: filing.compactMap(\.self))
		return [library, people, files]
	}
}
