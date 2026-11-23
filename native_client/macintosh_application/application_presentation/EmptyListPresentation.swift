import ApplicationBindings
import LibraryPresentation

public extension EmptyListPresentation {
	static func resolve(
		navigation: LibraryNavigationState,
		libraryStatus: LibraryStatus?,
		libraryFault: ApplicationFault?,
		listingFault: String?,
		hasCollector: Bool
	) -> EmptyListPresentation {
		let scope: LibraryScope? = if case let .library(listedScope, _) = navigation.destination {
			listedScope
		} else {
			nil
		}
		return resolve(
			scope: scope,
			searchText: navigation.searchText,
			libraryStatus: libraryStatus,
			libraryFault: libraryFault,
			listingFault: listingFault
		) ?? EmptyListPresentation(
			title: "No Documents Yet",
			detail: "Add a folder, and Schublade archives what is in it.",
			showsDocumentSourceButton: hasCollector,
			showsSearchAllDocumentsButton: false
		)
	}
}
