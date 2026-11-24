import AppKit

/// Stable accessibility and item identifiers shared between view controllers, renderer, and tests.
public enum InterfaceIdentifier {
	public static let mainWindow = NSUserInterfaceItemIdentifier("schublade.mainWindow")
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
	public static let documentListFooterSearchAll = "schublade.documentList.footerSearchAll"
	public static let documentListFooterIndexing = "schublade.documentList.footerIndexing"
	public static let documentRowTitle = "schublade.documentList.row.title"
	public static let documentRowSender = "schublade.documentList.row.sender"
	public static let documentRowDate = "schublade.documentList.row.date"
	public static let documentRowAmount = "schublade.documentList.row.amount"
	public static let documentRowDetail = "schublade.documentList.row.detail"
	public static let documentRowThumbnail = "schublade.documentList.row.thumbnail"
	public static let headingRowTitle = "schublade.documentList.heading.title"

	public static let readerPortableDocumentView = "schublade.reader.pdfView"
	public static let readerImageView = "schublade.reader.imageView"
	public static let readerTextView = "schublade.reader.textView"

	public static let inspectorScrollView = "schublade.inspector.scrollView"
	public static let inspectorTitleLabel = "schublade.inspector.titleLabel"
	public static let inspectorSummaryLabel = "schublade.inspector.summaryLabel"
	public static let inspectorOpenInBrowserButton = "schublade.inspector.openInBrowserButton"

	public static let emptyStateTitle = "schublade.emptyState.title"
	public static let emptyStateDetail = "schublade.emptyState.detail"
	public static let emptyStateAction = "schublade.emptyState.action"

	public static let folderPageTitle = "schublade.folderPage.title"
	public static let folderPageState = "schublade.folderPage.state"
	public static let folderPageUploadButton = "schublade.folderPage.uploadButton"
	public static let folderPageRemoveButton = "schublade.folderPage.removeButton"
	public static let folderPageMoreButton = "schublade.folderPage.moreButton"
	public static let folderPagePath = "schublade.folderPage.path"
	public static let folderPageFailure = "schublade.folderPage.failure"
}
