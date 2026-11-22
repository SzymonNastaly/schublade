import AppKit
import ApplicationBindings
import ApplicationPresentation
import PDFKit
import XCTest
@testable import ApplicationInterface

/// Xcode loads this bundle into the Debug application, which the scheme starts in the isolated
/// environment. XCTestCase is nonisolated, so the module keeps nonisolated default isolation.
final class ApplicationEndToEndTests: XCTestCase, InterfaceProbing {
	@MainActor
	func testConnectListReadInspectSearchAndCollectDocuments() async throws {
		let delegate = try XCTUnwrap(NSApp.delegate as? ApplicationDelegate)
		let controller = delegate.controller
		XCTAssertEqual(controller.environment.applicationConfiguration.credentialStorage, .processMemory)
		try await waitUntil("the application runs without an archive", controller) { statuses in
			statuses.library?.archive == .notConfigured
		}

		let validToken = "scripted-end-to-end-token"
		let server = try await ScriptedArchiveProcess.start(token: validToken, seedCount: 5)
		defer { server.stop() }

		let window = try XCTUnwrap(controller.mainWindowController.window)
		XCTAssertEqual(window.frame.size, NSSize(width: 1340, height: 820))

		try await connectThroughForm(in: window, address: server.baseURL.absoluteString, token: validToken)
		let tableView = try await assertSeededWorkspace(in: window)
		try await verifySelectionReaderAndInspector(in: window, tableView: tableView)
		try await verifyIncrementalSearchAndSenderFilter(
			in: window,
			tableView: tableView,
			controller: controller,
			server: server
		)
		try await verifyCollectedDocumentArrives(in: window, tableView: tableView, controller: controller)
		verifyWindowReopen(window: window, tableView: tableView, controller: controller)
	}
}

@MainActor
private extension ApplicationEndToEndTests {
	func connectThroughForm(in window: NSWindow, address: String, token: String) async throws {
		let addressField = try await waitForView(
			"the connection address field",
			in: window,
			identifier: InterfaceIdentifier.connectionAddressField,
			as: NSTextField.self
		)
		let tokenField = try await waitForView(
			"the connection token field",
			in: window,
			identifier: InterfaceIdentifier.connectionTokenField,
			as: NSSecureTextField.self
		)
		let submitButton = try await waitForView(
			"the connect button",
			in: window,
			identifier: InterfaceIdentifier.connectionSubmitButton,
			as: NSButton.self
		)

		addressField.stringValue = address
		tokenField.stringValue = "wrong-token"
		submitButton.performClick(nil)

		let refusalLabel = try await waitForView(
			"the token refusal message",
			in: window,
			identifier: InterfaceIdentifier.connectionRefusalLabel,
			as: NSTextField.self
		) { !$0.isHidden && !$0.stringValue.isEmpty }
		XCTAssertEqual(
			refusalLabel.stringValue,
			"Schublade refused this token. Check that you copied all of it and that it was not revoked."
		)

		tokenField.stringValue = token
		submitButton.performClick(nil)
	}

	func assertSeededWorkspace(in window: NSWindow) async throws -> NSTableView {
		let tableView = try await waitForView(
			"the seeded documents in the library list",
			in: window,
			identifier: InterfaceIdentifier.documentListTable,
			as: NSTableView.self
		) { $0.numberOfRows == 6 }
		XCTAssertEqual(window.frame.size, NSSize(width: 1340, height: 820))

		let statusLabel = try await waitForView(
			"the sidebar status line",
			in: window,
			identifier: InterfaceIdentifier.sidebarStatusLabel,
			as: NSTextField.self
		) { $0.stringValue.hasPrefix("Up to date · ") }
		XCTAssertTrue(statusLabel.stringValue.hasPrefix("Up to date · "))

		window.contentView?.layoutSubtreeIfNeeded()
		XCTAssertEqual(
			try rowText(in: tableView, row: 0, identifier: InterfaceIdentifier.headingRowTitle),
			"September 2026"
		)
		for index in 1 ... 5 {
			let expectedNumber = 6 - index
			XCTAssertEqual(
				try rowText(in: tableView, row: index, identifier: InterfaceIdentifier.documentRowTitle),
				"Haftpflichtversicherung Rechnung \(expectedNumber)"
			)
			XCTAssertEqual(
				try rowText(in: tableView, row: index, identifier: InterfaceIdentifier.documentRowSender),
				"Stadtwerke Talbrück GmbH"
			)
			XCTAssertEqual(
				try rowText(in: tableView, row: index, identifier: InterfaceIdentifier.documentRowAmount),
				"72.09 EUR"
			)
		}
		return tableView
	}

	func verifySelectionReaderAndInspector(in window: NSWindow, tableView: NSTableView) async throws {
		tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

		let readerTitle = try await waitForView(
			"reader title for selected invoice",
			in: window,
			identifier: InterfaceIdentifier.readerTitleLabel,
			as: NSTextField.self
		) { $0.stringValue == "Haftpflichtversicherung Rechnung 5" }
		XCTAssertEqual(readerTitle.stringValue, "Haftpflichtversicherung Rechnung 5")

		let pdfView = try await waitForView(
			"the loaded PDF document",
			in: window,
			identifier: InterfaceIdentifier.readerPortableDocumentView,
			as: PDFView.self
		) { ($0.document?.pageCount ?? 0) == 1 }
		XCTAssertEqual(pdfView.document?.pageCount, 1)

		let senderButton = try await waitForView(
			"inspector sender link",
			in: window,
			identifier: "inspector.field.sender",
			as: NSButton.self
		) { $0.title == "Stadtwerke Talbrück GmbH" }
		XCTAssertEqual(senderButton.title, "Stadtwerke Talbrück GmbH")

		let amountLabel = try await waitForView(
			"inspector amount field",
			in: window,
			identifier: "inspector.field.amount",
			as: NSTextField.self
		) { $0.stringValue == "72.09 EUR" }
		XCTAssertEqual(amountLabel.stringValue, "72.09 EUR")

		let tabControl = try XCTUnwrap(findView(
			in: window.contentView,
			identifier: InterfaceIdentifier.readerTabControl,
			as: NSSegmentedControl.self
		))
		tabControl.selectedSegment = 1
		tabControl.sendAction(tabControl.action, to: tabControl.target)

		let textView = try await waitForView(
			"extracted text in reader Text tab",
			in: window,
			identifier: InterfaceIdentifier.readerTextView,
			as: NSTextView.self
		) { $0.enclosingScrollView?.isHidden == false && $0.string.contains("Rechnung Nummer 5") }
		XCTAssertTrue(textView.string.contains("Rechnung Nummer 5 für Haftpflichtversicherung."))

		tabControl.selectedSegment = 0
		tabControl.sendAction(tabControl.action, to: tabControl.target)
	}

	func verifyIncrementalSearchAndSenderFilter(
		in window: NSWindow,
		tableView: NSTableView,
		controller: ApplicationController,
		server: ScriptedArchiveProcess
	) async throws {
		let workspace = try XCTUnwrap(controller.mainWindowController.activeWorkspaceController)
		let updatesBefore = workspace.listController.incrementalUpdateCount
		let existingRowCell = try XCTUnwrap(tableView.view(atColumn: 0, row: 1, makeIfNecessary: false))

		try await server.seedDocument(SeededDocument(
			identifier: "50000000-0000-4000-8000-000000000099",
			title: "Kontoauszug Oktober 2026",
			documentDate: "2026-10-15",
			senderName: "Nordbank AG",
			categoryName: "Statement",
			summary: "Monthly account statement."
		))
		workspace.synchronizeLibrary(nil)

		try await waitForCondition("the incremental update for October statement") { tableView.numberOfRows == 8 }
		window.contentView?.layoutSubtreeIfNeeded()
		XCTAssertEqual(workspace.listController.incrementalUpdateCount, updatesBefore + 1)
		XCTAssertTrue(tableView.view(atColumn: 0, row: 3, makeIfNecessary: false) === existingRowCell)

		let searchField = try XCTUnwrap(findSearchField(in: window))
		searchField.stringValue = "Nordbank"
		searchField.sendAction(searchField.action, to: searchField.target)
		try await waitForCondition("search narrows list to Nordbank match") { tableView.numberOfRows == 2 }
		window.contentView?.layoutSubtreeIfNeeded()
		XCTAssertEqual(
			try rowText(in: tableView, row: 0, identifier: InterfaceIdentifier.headingRowTitle),
			"Matches in Details"
		)
		XCTAssertEqual(
			try rowText(in: tableView, row: 1, identifier: InterfaceIdentifier.documentRowTitle),
			"Kontoauszug Oktober 2026"
		)

		searchField.stringValue = ""
		searchField.sendAction(searchField.action, to: searchField.target)
		try await waitForCondition("clearing search restores full list") { tableView.numberOfRows == 8 }
		try await verifySenderListAndBack(in: window, tableView: tableView)
	}

	/// The inspector's sender lists that sender's documents under its name, and Back returns.
	func verifySenderListAndBack(in window: NSWindow, tableView: NSTableView) async throws {
		tableView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
		let senderLink = try await waitForView(
			"inspector sender link after the search",
			in: window,
			identifier: "inspector.field.sender",
			as: NSButton.self
		) { $0.title == "Stadtwerke Talbrück GmbH" }
		senderLink.performClick(nil)
		try await waitForCondition("the sender's documents are listed under its name") {
			window.title == "Stadtwerke Talbrück GmbH" && tableView.numberOfRows == 6
		}
		let backItem = window.toolbar?.items.first { $0.itemIdentifier.rawValue == "schublade.back" }
		let backButton = try XCTUnwrap(backItem?.view as? NSButton)
		backButton.performClick(nil)
		try await waitForCondition("Back returns to All Documents") {
			window.title == "All Documents" && tableView.numberOfRows == 8
		}
	}

	func verifyCollectedDocumentArrives(
		in window: NSWindow,
		tableView: NSTableView,
		controller: ApplicationController
	) async throws {
		let folder = URL.temporaryDirectory.appending(
			path: "schublade_end_to_end_\(UUID().uuidString)",
			directoryHint: .isDirectory
		)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(at: folder) }

		let fixtureFile = repositoryRoot()
			.appending(path: "test_fixtures/collection_corpus/Downloads/Meldebescheinigung.pdf")
		try FileManager.default.copyItem(at: fixtureFile, to: folder.appending(path: "Meldebescheinigung.pdf"))

		let enrolled = try await controller.collectorCommands.enrollFolder(root: folder.path(percentEncoded: false))
		try await waitUntil("the enrolled folder awaits decision", controller) { statuses in
			statuses.collector?.folders.contains { listed in
				guard listed.folder == enrolled, case .awaitingDecision = listed.admission else { return false }
				return true
			} ?? false
		}
		try await decideOnTheFolderPage(enrolled, in: window, controller: controller)

		try await waitForCondition("collected document appearing under Arriving") { tableView.numberOfRows == 10 }
		window.contentView?.layoutSubtreeIfNeeded()
		XCTAssertEqual(try rowText(in: tableView, row: 0, identifier: InterfaceIdentifier.headingRowTitle), "Arriving")
		XCTAssertEqual(
			try rowText(in: tableView, row: 1, identifier: InterfaceIdentifier.documentRowTitle),
			"Processing Document"
		)
	}

	/// Opens the folder's page as a notification does, and presses the confirmation's upload.
	func decideOnTheFolderPage(
		_ folder: FolderReference,
		in window: NSWindow,
		controller: ApplicationController
	) async throws {
		controller.mainWindowController.open(.decideBacklog(folder.identifier))
		let upload = try await waitForView(
			"the confirmation's upload button",
			in: window,
			identifier: InterfaceIdentifier.folderPageUploadButton,
			as: NSButton.self
		) { $0.isEnabled }
		XCTAssertEqual(window.frame.size, NSSize(width: 1340, height: 820))
		upload.performClick(nil)
		_ = try await waitForView(
			"the folder collecting",
			in: window,
			identifier: InterfaceIdentifier.folderPageState,
			as: NSTextField.self
		) { $0.stringValue == "Collecting" }
		let sidebar = try XCTUnwrap(findView(
			in: window.contentView,
			identifier: InterfaceIdentifier.sidebarOutline,
			as: NSOutlineView.self
		))
		let allDocuments = try XCTUnwrap((0 ..< sidebar.numberOfRows).first { row in
			sidebar.view(atColumn: 0, row: row, makeIfNecessary: true)?.accessibilityIdentifier()
				== "sidebarItem.library.allDocuments"
		})
		sidebar.selectRowIndexes(IndexSet(integer: allDocuments), byExtendingSelection: false)
	}

	func verifyWindowReopen(window: NSWindow, tableView: NSTableView, controller: ApplicationController) {
		window.close()
		XCTAssertFalse(window.isVisible)
		XCTAssertEqual(NSApp.activationPolicy(), .accessory)
		XCTAssertFalse(controller.mainWindowController.isAttending)

		controller.showMainWindow()
		XCTAssertTrue(window.isVisible)
		XCTAssertEqual(NSApp.activationPolicy(), .regular)
		XCTAssertEqual(tableView.numberOfRows, 10)
		if window.occlusionState.contains(.visible) {
			XCTAssertTrue(controller.mainWindowController.isAttending)
		}
	}
}
