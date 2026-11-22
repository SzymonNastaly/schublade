import ApplicationBindings

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

	public init(
		windowTitle: String,
		countsShownDocuments: Bool,
		showsBackButton: Bool,
		detailMode: WorkspaceDetailMode,
		sidebar: SidebarPresentation,
		allowsSortSelection: Bool,
		effectiveOrder: ListingOrder,
		searchAllDocumentsAvailable: Bool,
		textIndexingNotice: String?
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
	}

	/// The window's subtitle, such as "412 documents", once the list holds a listing.
	public func windowSubtitle(shownDocuments: Int?) -> String {
		guard countsShownDocuments, let shownDocuments else {
			return ""
		}
		return DocumentFormatting.countText(UInt64(shownDocuments), singular: "document")
	}
}
