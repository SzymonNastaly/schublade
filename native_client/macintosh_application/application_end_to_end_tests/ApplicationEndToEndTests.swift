import AppKit
import ApplicationBindings
import ApplicationPresentation
import PDFKit
import XCTest
@testable import ApplicationInterface

/// Xcode loads this bundle into the Debug application, which the scheme starts in the isolated
/// environment. XCTestCase is nonisolated, so the module keeps nonisolated default isolation.
final class ApplicationEndToEndTests: XCTestCase {
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

private extension ApplicationEndToEndTests {
	@MainActor
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

	@MainActor
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

	@MainActor
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
		) { !$0.isHidden && $0.string.contains("Rechnung Nummer 5") }
		XCTAssertTrue(textView.string.contains("Rechnung Nummer 5 für Haftpflichtversicherung."))

		tabControl.selectedSegment = 0
		tabControl.sendAction(tabControl.action, to: tabControl.target)
	}

	@MainActor
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

		searchField.stringValue = ""
		searchField.sendAction(searchField.action, to: searchField.target)
		try await waitForCondition("clearing search restores full list") { tableView.numberOfRows == 8 }
	}

	@MainActor
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
		try await controller.collectorCommands.decideBacklog(enrolled.identifier)

		try await waitForCondition("collected document appearing under Arriving") { tableView.numberOfRows == 10 }
		window.contentView?.layoutSubtreeIfNeeded()
		XCTAssertEqual(try rowText(in: tableView, row: 0, identifier: InterfaceIdentifier.headingRowTitle), "Arriving")
		XCTAssertEqual(
			try rowText(in: tableView, row: 1, identifier: InterfaceIdentifier.documentRowTitle),
			"Processing Document"
		)
	}

	@MainActor
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

	@MainActor
	func findSearchField(in window: NSWindow) -> NSSearchField? {
		for item in window.toolbar?.items ?? [] {
			if let searchItem = item as? NSSearchToolbarItem {
				return searchItem.searchField
			}
		}
		return nil
	}

	@MainActor
	func waitUntil(
		_ expectation: String,
		_ controller: ApplicationController,
		_ condition: (ApplicationStatuses) -> Bool
	) async throws {
		let deadline = ContinuousClock.now + .seconds(30)
		while true {
			if case let .running(statuses) = controller.situation, condition(statuses) {
				return
			}
			guard ContinuousClock.now < deadline else {
				throw ConditionNotReached(expectation: expectation, detail: String(describing: controller.situation))
			}
			try await Task.sleep(for: .milliseconds(50))
		}
	}

	@MainActor
	func waitForCondition(_ expectation: String, _ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now + .seconds(30)
		while !condition() {
			guard ContinuousClock.now < deadline else {
				throw ConditionNotReached(expectation: expectation, detail: "timed out")
			}
			try await Task.sleep(for: .milliseconds(50))
		}
	}

	@MainActor
	func waitForView<View: NSView>(
		_ expectation: String,
		in window: NSWindow,
		identifier: String,
		as _: View.Type,
		matching predicate: (View) -> Bool = { _ in true }
	) async throws -> View {
		let deadline = ContinuousClock.now + .seconds(30)
		while true {
			if let view = findView(in: window.contentView, identifier: identifier, as: View.self), predicate(view) {
				return view
			}
			guard ContinuousClock.now < deadline else {
				throw ConditionNotReached(expectation: expectation, detail: "missing view \(identifier)")
			}
			try await Task.sleep(for: .milliseconds(50))
		}
	}

	@MainActor
	func rowText(in tableView: NSTableView, row: Int, identifier: String) throws -> String {
		let rowView = try XCTUnwrap(tableView.rowView(atRow: row, makeIfNecessary: true))
		let label = try XCTUnwrap(findView(in: rowView, identifier: identifier, as: NSTextField.self))
		return label.stringValue
	}

	@MainActor
	func findView<View: NSView>(in root: NSView?, identifier: String, as _: View.Type) -> View? {
		guard let root else { return nil }
		if root.accessibilityIdentifier() == identifier, let matching = root as? View {
			return matching
		}
		for subview in root.subviews {
			if let found = findView(in: subview, identifier: identifier, as: View.self) {
				return found
			}
		}
		return nil
	}

	func repositoryRoot() -> URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
	}
}
