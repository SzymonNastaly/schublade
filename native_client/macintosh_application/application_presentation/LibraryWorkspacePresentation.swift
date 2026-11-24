import ApplicationBindings
import LibraryPresentation

/// Presentation state of the four-part library workspace window.
public struct LibraryWorkspacePresentation: Equatable, Sendable {
	public let windowTitle: String
	/// Whether the subtitle counts the documents the list shows, which only the list knows.
	public let countsShownDocuments: Bool
	public let showsBackButton: Bool
	public let detailMode: WorkspaceDetailMode
	public let sidebar: SidebarPresentation
	public let allowsSortSelection: Bool
	public let effectiveOrder: ListingOrder
	public let searchAllDocumentsAvailable: Bool
	public let textIndexingNotice: String?
	/// Names what a search looks through, such as "Search Invoice". A page has no list, so a search
	/// typed there looks through All Documents.
	public let searchPlaceholder: String

	/// Whether Original and Text apply, in the toolbar and in View alike: a document of the list is
	/// selected.
	public func offersReaderTabs(for navigation: LibraryNavigationState) -> Bool {
		detailMode == .documents && navigation.selectedDocument != nil
	}

	public init(
		windowTitle: String,
		countsShownDocuments: Bool,
		showsBackButton: Bool,
		detailMode: WorkspaceDetailMode,
		sidebar: SidebarPresentation,
		allowsSortSelection: Bool,
		effectiveOrder: ListingOrder,
		searchAllDocumentsAvailable: Bool,
		textIndexingNotice: String?,
		searchPlaceholder: String
	) {
		self.windowTitle = windowTitle
		self.countsShownDocuments = countsShownDocuments
		self.showsBackButton = showsBackButton
		self.detailMode = detailMode
		self.sidebar = sidebar
		self.allowsSortSelection = allowsSortSelection
		self.effectiveOrder = effectiveOrder
		self.searchAllDocumentsAvailable = searchAllDocumentsAvailable
		self.textIndexingNotice = textIndexingNotice
		self.searchPlaceholder = searchPlaceholder
	}

	/// The window's subtitle, such as "412 documents", once the list holds a listing.
	public func windowSubtitle(shownDocuments: Int?) -> String {
		guard countsShownDocuments, let shownDocuments else {
			return ""
		}
		return DocumentFormatting.countText(UInt64(shownDocuments), singular: "document")
	}
}
