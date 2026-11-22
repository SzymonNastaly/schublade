import ApplicationBindings

/// Message and optional actions shown when the active listing returns zero rows.
public struct EmptyListPresentation: Equatable, Sendable {
	public let title: String
	public let detail: String
	public let showsAddFolderButton: Bool
	public let showsSearchAllDocumentsButton: Bool

	public init(
		title: String,
		detail: String,
		showsAddFolderButton: Bool,
		showsSearchAllDocumentsButton: Bool
	) {
		self.title = title
		self.detail = detail
		self.showsAddFolderButton = showsAddFolderButton
		self.showsSearchAllDocumentsButton = showsSearchAllDocumentsButton
	}

	public static func resolve(
		navigation: LibraryNavigationState,
		libraryStatus: LibraryStatus?,
		libraryFault: ApplicationFault?,
		listingFault: String?,
		hasCollector: Bool
	) -> EmptyListPresentation {
		if let listingFault {
			return EmptyListPresentation(
				title: "Could Not Read Documents",
				detail: listingFault,
				showsAddFolderButton: false,
				showsSearchAllDocumentsButton: false
			)
		}
		if let libraryFault {
			return EmptyListPresentation(
				title: "Library Unavailable",
				detail: ApplicationFailureWording.faultSentence(libraryFault),
				showsAddFolderButton: false,
				showsSearchAllDocumentsButton: false
			)
		}
		if !navigation.trimmedSearchText.isEmpty {
			let inAllDocuments = navigation.destination == .library(.allDocuments, title: nil)
			return EmptyListPresentation(
				title: "No Matching Documents",
				detail: inAllDocuments
					? "Try another word or clear the search field."
					: "Nothing here matched \"\(navigation.trimmedSearchText)\".",
				showsAddFolderButton: false,
				showsSearchAllDocumentsButton: !inAllDocuments
			)
		}
		if case .filling = libraryStatus?.copy {
			return EmptyListPresentation(
				title: "Loading Documents…",
				detail: "Reading the archive into your local copy.",
				showsAddFolderButton: false,
				showsSearchAllDocumentsButton: false
			)
		}
		if (libraryStatus?.counts.documents ?? 0) > 0 {
			let (title, detail) = emptyScopeWording(navigation.destination)
			return EmptyListPresentation(
				title: title,
				detail: detail,
				showsAddFolderButton: false,
				showsSearchAllDocumentsButton: false
			)
		}
		return EmptyListPresentation(
			title: "No Documents Yet",
			detail: "Add a folder, and Schublade archives what is in it.",
			showsAddFolderButton: hasCollector,
			showsSearchAllDocumentsButton: false
		)
	}

	/// An empty entry of an archive that holds documents elsewhere.
	private static func emptyScopeWording(_ destination: NavigationDestination) -> (String, String) {
		guard case let .library(scope, _) = destination else {
			return ("No Documents", "No document belongs here.")
		}
		return switch scope {
		case .recentlyAdded:
			("Nothing Added Recently", "Documents the archive received in the last 30 days appear here.")
		case .inIngestion:
			("Nothing Arriving", "Documents appear here while the archive reads them.")
		case .failed:
			("No Failed Documents", "Every document the archive received was read.")
		case .allDocuments, .household, .member, .category, .tag, .sender:
			("No Documents", "No document belongs here.")
		}
	}
}
