import ApplicationBindings
import LibraryPresentation

/// The picture above an empty state's title.
public enum EmptyStatePicture: Equatable, Sendable {
	case symbol(String)
	/// The drawer of the application's icon, empty.
	case emptyDrawer
	/// A spinner, while the copy fills.
	case progress
}

/// The one way out an empty state offers.
public enum EmptyStateAction: Equatable, Sendable {
	case addFolder
	case searchAllDocuments
	case replaceToken
	case tryAgain

	public var title: String {
		switch self {
		case .addFolder: "Add Folder…"
		case .searchAllDocuments: "Search All Documents"
		case .replaceToken: "Replace Token…"
		case .tryAgain: "Try Again"
		}
	}
}

/// What a list or a page shows when it has nothing to show: a picture, a title, a detail, and at
/// most one action.
public struct EmptyStatePresentation: Equatable, Sendable {
	public let picture: EmptyStatePicture
	public let title: String
	public let detail: String
	public let action: EmptyStateAction?

	public init(picture: EmptyStatePicture, title: String, detail: String, action: EmptyStateAction?) {
		self.picture = picture
		self.title = title
		self.detail = detail
		self.action = action
	}

	/// The archive holds no document at all. Only a Mac that collects can add a folder.
	public static func emptyArchive(offersFolders: Bool) -> EmptyStatePresentation {
		EmptyStatePresentation(
			picture: .emptyDrawer,
			title: "No Documents Yet",
			detail: offersFolders
				? "Add a folder, and Schublade archives the PDFs and pictures in it. "
				+ "Documents from your iPhone and the browser appear here too."
				: "Documents from your iPhone and the browser appear here.",
			action: offersFolders ? .addFolder : nil
		)
	}

	/// The page that takes the place of the list, the reader, and the inspector, for a mode that
	/// shows no documents and is not a folder or Needs Attention.
	public static func page(_ mode: WorkspaceDetailMode) -> EmptyStatePresentation? {
		switch mode {
		case let .emptyArchive(offersFolders):
			emptyArchive(offersFolders: offersFolders)
		case let .archiveOutdated(message):
			EmptyStatePresentation(
				picture: .symbol("exclamationmark.triangle"),
				title: "Update Required",
				detail: message,
				action: nil
			)
		case let .tokenCannotRead(message):
			EmptyStatePresentation(
				picture: .symbol("lock"),
				title: "Token Cannot Read Archive",
				detail: message,
				action: .replaceToken
			)
		case .documents, .needsAttention, .folder:
			nil
		}
	}

	/// The list of a scope that holds no row, from the wording both devices share.
	public static func list(
		navigation: LibraryNavigationState,
		libraryStatus: LibraryStatus?,
		libraryFault: ApplicationFault?,
		listingFault: String?,
		hasCollector: Bool
	) -> EmptyStatePresentation {
		let scope: LibraryScope? = if case let .library(listedScope, _) = navigation.destination {
			listedScope
		} else {
			nil
		}
		guard let shared = EmptyListPresentation.resolve(
			scope: scope,
			searchText: navigation.searchText,
			libraryStatus: libraryStatus,
			libraryFault: libraryFault,
			listingFault: listingFault
		) else {
			// The window shows the empty archive as a page once the copy is complete, so the list
			// meets this only before the copy began or for the moment before the page replaces it.
			if case .complete = libraryStatus?.copy {
				return emptyArchive(offersFolders: hasCollector)
			}
			return EmptyStatePresentation(
				picture: .progress,
				title: "Loading Documents…",
				detail: "Reading the archive into your local copy.",
				action: nil
			)
		}
		let picture: EmptyStatePicture = if listingFault != nil || libraryFault != nil {
			.symbol("exclamationmark.triangle")
		} else if !navigation.trimmedSearchText.isEmpty {
			.symbol("magnifyingglass")
		} else if case .filling = libraryStatus?.copy {
			.progress
		} else {
			.symbol("tray")
		}
		return EmptyStatePresentation(
			picture: picture,
			title: shared.title,
			detail: shared.detail,
			action: shared.showsSearchAllDocumentsButton ? .searchAllDocuments : nil
		)
	}
}
