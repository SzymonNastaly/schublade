import AppKit

/// Stable accessibility and item identifiers shared between view controllers, renderer, and tests.
public enum InterfaceIdentifier {
	public static let mainWindow = NSUserInterfaceItemIdentifier("schublade.mainWindow")
	public static let startFailureMessage = "schublade.startFailure.message"
	public static let statusMessage = "schublade.status.message"
	public static let connectionAddressField = "schublade.connection.addressField"
	public static let connectionTokenField = "schublade.connection.tokenField"
	public static let connectionSubmitButton = "schublade.connection.submitButton"
	public static let connectionCancelButton = "schublade.connection.cancelButton"
	public static let connectionRefusalLabel = "schublade.connection.refusalLabel"

	public static let sidebarOutline = "schublade.sidebar.outline"
	public static let sidebarStatusButton = "schublade.sidebar.statusButton"
	public static let sidebarStatusLabel = "schublade.sidebar.statusLabel"
	public static let sidebarStatusProgress = "schublade.sidebar.statusProgress"

	public static let toolbarSearchField = "schublade.toolbar.searchField"

	public static let documentListTable = "schublade.documentList.table"
	public static let documentListEmptyTitle = "schublade.documentList.emptyTitle"
	public static let documentListEmptyDetail = "schublade.documentList.emptyDetail"
	public static let documentListEmptyAddFolder = "schublade.documentList.emptyAddFolder"
	public static let documentListEmptySearchAll = "schublade.documentList.emptySearchAll"
	public static let documentListFooterSearchAll = "schublade.documentList.footerSearchAll"
	public static let documentListFooterIndexing = "schublade.documentList.footerIndexing"
	public static let documentRowTitle = "schublade.documentList.row.title"
	public static let documentRowSender = "schublade.documentList.row.sender"
	public static let documentRowDate = "schublade.documentList.row.date"
	public static let documentRowAmount = "schublade.documentList.row.amount"
	public static let documentRowDetail = "schublade.documentList.row.detail"
	public static let documentRowThumbnail = "schublade.documentList.row.thumbnail"
	public static let headingRowTitle = "schublade.documentList.heading.title"

	public static let readerTitleLabel = "schublade.reader.titleLabel"
	public static let readerSubtitleLabel = "schublade.reader.subtitleLabel"
	public static let readerTabControl = "schublade.reader.tabControl"
	public static let readerPortableDocumentView = "schublade.reader.pdfView"
	public static let readerImageView = "schublade.reader.imageView"
	public static let readerTextView = "schublade.reader.textView"
	public static let readerPlaceholderTitle = "schublade.reader.placeholderTitle"
	public static let readerPlaceholderDetail = "schublade.reader.placeholderDetail"
	public static let readerPlaceholderAction = "schublade.reader.placeholderAction"

	public static let inspectorScrollView = "schublade.inspector.scrollView"
	public static let inspectorSummaryLabel = "schublade.inspector.summaryLabel"
	public static let inspectorOpenInBrowserButton = "schublade.inspector.openInBrowserButton"

	public static let workspaceNoticeMessage = "schublade.workspace.noticeMessage"
	public static let folderPageTitle = "schublade.folderPage.title"
	public static let folderPageState = "schublade.folderPage.state"
	public static let folderPageUploadButton = "schublade.folderPage.uploadButton"
	public static let folderPageRemoveButton = "schublade.folderPage.removeButton"
	public static let folderPageFailure = "schublade.folderPage.failure"
	public static let workspaceNoticeActionButton = "schublade.workspace.noticeActionButton"
}
