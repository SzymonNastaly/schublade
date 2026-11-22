import AppKit

/// Stable accessibility and item identifiers shared between view controllers and end-to-end tests.
enum InterfaceIdentifier {
	static let mainWindow = NSUserInterfaceItemIdentifier("schublade.mainWindow")
	static let startFailureMessage = "schublade.startFailure.message"
	static let statusMessage = "schublade.status.message"
	static let connectionAddressField = "schublade.connection.addressField"
	static let connectionTokenField = "schublade.connection.tokenField"
	static let connectionSubmitButton = "schublade.connection.submitButton"
	static let connectionRefusalLabel = "schublade.connection.refusalLabel"
	static let documentListSummaryLabel = "schublade.documentList.summaryLabel"
	static let documentListRefreshButton = "schublade.documentList.refreshButton"
	static let documentListTable = "schublade.documentList.table"
	static let documentListEmptyLabel = "schublade.documentList.emptyLabel"
	static let documentRowTitle = "schublade.documentList.row.title"
	static let documentRowSender = "schublade.documentList.row.sender"
	static let documentRowDetail = "schublade.documentList.row.detail"
	static let headingRowTitle = "schublade.documentList.heading.title"
}
