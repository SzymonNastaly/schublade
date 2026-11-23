import ApplicationBindings
import LibraryPresentation
import UIKit

/// The filter menu of the library screen: the Mac's sidebar scopes, each with its count, and the
/// chosen one checked.
enum LibraryScopeMenu {
	static func menu(
		facets: LibraryFacets?,
		chosen: LibraryScope,
		choose: @escaping (NamedScope) -> Void
	) -> UIMenu {
		func action(_ scope: LibraryScope, name: String? = nil, count: UInt64?, symbol: String) -> UIAction {
			let title = LibraryScopePresentation.resolve(
				scope: scope,
				name: name,
				searchText: "",
				browseOrder: .documentDate
			).title
			let action = UIAction(title: title, image: UIImage(systemName: symbol)) { _ in
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
				action(count.scope.scope, name: count.scope.name, count: count.documents, symbol: symbol)
			})
			if counts.contains(where: { $0.scope.scope == chosen }) {
				menu.subtitle = counts.first { $0.scope.scope == chosen }?.scope.name
			}
			return menu
		}

		let library = UIMenu(options: .displayInline, children: [
			action(.allDocuments, count: facets?.documents, symbol: "tray.full"),
			action(.recentlyAdded, count: nil, symbol: "clock"),
			action(.inIngestion, count: facets?.documentsInIngestion, symbol: "arrow.down.circle"),
			action(.failed, count: facets?.documentsFailed, symbol: "exclamationmark.triangle"),
		])
		let household: [UIMenuElement?] = [
			action(.household, count: facets?.householdDocuments, symbol: "house"),
			submenu("People", symbol: "person", facets?.members ?? []),
		]
		let filing: [UIMenuElement?] = [
			submenu("Categories", symbol: "folder", facets?.categories ?? []),
			submenu("Tags", symbol: "tag", facets?.tags ?? []),
		]
		let people = UIMenu(options: .displayInline, children: household.compactMap(\.self))
		let files = UIMenu(options: .displayInline, children: filing.compactMap(\.self))
		return UIMenu(title: "Show", children: [library, people, files])
	}
}
