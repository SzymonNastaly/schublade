import ApplicationBindings
import ApplicationPresentation

/// How the window's navigation changes, and the scope and document it reopens on.
extension MainWindowController {
	func updateNavigation(_ mutate: (inout LibraryNavigationState) -> Void) {
		mutate(&navigation)
		rememberPlace()
		if preferences.inspectorVisible != navigation.inspectorVisible {
			preferences.inspectorVisible = navigation.inspectorVisible
		}
		render(latestSituation)
	}

	func setBrowseOrder(_ order: ListingOrder) {
		updateNavigation { $0.browseOrder = order }
	}

	func setSearchText(_ text: String) {
		guard navigation.searchText != text else {
			return
		}
		updateNavigation { $0.search(text) }
	}

	func navigateBack() {
		updateNavigation { navigation in
			navigation.destination = navigation.previousDestination ?? .library(.allDocuments, title: nil)
			navigation.previousDestination = nil
			navigation.selectedDocument = nil
		}
	}

	func rememberPlace() {
		if let place = RememberedLibraryPlace(navigation), place != preferences.libraryPlace {
			preferences.libraryPlace = place
		}
	}

	/// The restored place takes the title the sidebar shows now, and a place the sidebar no longer
	/// lists, such as a removed category or Arriving with nothing arriving, leaves All Documents.
	func checkRestoredPlace(against facets: LibraryFacets) {
		guard let place = restoredPlace, case let .running(statuses) = latestSituation else {
			return
		}
		restoredPlace = nil
		guard navigation.destination == .library(place.scope, title: place.scopeName) else {
			return
		}
		let sidebar = SidebarPresentation.resolve(statuses: statuses, facets: facets, context: wordingContextProvider())
		navigation.destination = place.listedDestination(in: sidebar) ?? .library(.allDocuments, title: nil)
		rememberPlace()
	}
}
