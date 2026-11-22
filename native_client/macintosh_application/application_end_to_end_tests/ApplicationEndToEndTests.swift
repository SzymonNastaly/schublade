import AppKit
import ApplicationBindings
import XCTest
@testable import ApplicationInterface

/// Xcode loads this bundle into the Debug application, which the scheme starts in the isolated
/// environment. XCTestCase is nonisolated, so the module keeps nonisolated default isolation.
final class ApplicationEndToEndTests: XCTestCase {
	@MainActor
	func testConnectListSeededAndCollectedDocuments() async throws {
		let delegate = try XCTUnwrap(NSApp.delegate as? ApplicationDelegate)
		let controller = delegate.controller
		XCTAssertEqual(controller.environment.applicationConfiguration.credentialStorage, .processMemory)
		try await waitUntil("the application runs without an archive", controller) { statuses in
			statuses.library?.archive == .notConfigured
		}
		XCTAssertNotNil(controller.statusItem.item.button)
		XCTAssertTrue(controller.statusItem.item.isVisible)

		let validToken = "scripted-end-to-end-token"
		let server = try await ScriptedArchiveProcess.start(token: validToken, seedCount: 5)
		defer {
			server.stop()
		}

		let window = try XCTUnwrap(controller.mainWindowController.window)
		XCTAssertTrue(window.isVisible)
		XCTAssertEqual(window.contentLayoutRect.size, NSSize(width: 1340, height: 820))

		try await connectThroughForm(in: window, address: server.baseURL.absoluteString, token: validToken)
		let tableView = try await assertSeededRows(in: window)
		XCTAssertEqual(window.contentLayoutRect.size, NSSize(width: 1340, height: 820))
		try await verifyIncrementalDocumentUpdate(
			in: window,
			tableView: tableView,
			controller: controller,
			server: server
		)
		try await verifyCollectedDocumentArrives(in: window, tableView: tableView, controller: controller)
		verifyWindowReopen(window: window, tableView: tableView, controller: controller)
	}

	@MainActor
	private func connectThroughForm(in window: NSWindow, address: String, token: String) async throws {
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
		) { label in
			!label.isHidden && !label.stringValue.isEmpty
		}
		XCTAssertEqual(
			refusalLabel.stringValue,
			"Schublade refused this token. Check that you copied all of it and that it was not revoked."
		)

		tokenField.stringValue = token
		submitButton.performClick(nil)
	}

	@MainActor
	private func assertSeededRows(in window: NSWindow) async throws -> NSTableView {
		let tableView = try await waitForView(
			"the seeded documents in the plain table",
			in: window,
			identifier: InterfaceIdentifier.documentListTable,
			as: NSTableView.self
		) { table in
			table.numberOfRows == 6
		}
		let summaryLabel = try await waitForView(
			"the document count summary",
			in: window,
			identifier: InterfaceIdentifier.documentListSummaryLabel,
			as: NSTextField.self
		) { label in
			label.stringValue.hasPrefix("5 documents")
		}
		XCTAssertTrue(summaryLabel.stringValue.hasPrefix("5 documents"))

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
		}
		return tableView
	}

	@MainActor
	private func verifyIncrementalDocumentUpdate(
		in window: NSWindow,
		tableView: NSTableView,
		controller: ApplicationController,
		server: ScriptedArchiveProcess
	) async throws {
		let listController = try XCTUnwrap(controller.mainWindowController.activeDocumentListController)
		let updatesBefore = listController.incrementalUpdateCount
		let existingRowCell = try XCTUnwrap(tableView.view(atColumn: 0, row: 1, makeIfNecessary: false))

		try await server.seedDocument(SeededDocument(
			identifier: "50000000-0000-4000-8000-000000000099",
			title: "Kontoauszug Oktober 2026",
			documentDate: "2026-10-15",
			senderName: "Nordbank AG",
			categoryName: "Statement",
			summary: "Monthly account statement."
		))

		let refreshButton = try await waitForView(
			"the refresh button",
			in: window,
			identifier: InterfaceIdentifier.documentListRefreshButton,
			as: NSButton.self
		)
		refreshButton.performClick(nil)

		try await waitForCondition("the incremental document update in the table") {
			tableView.numberOfRows == 8
		}
		window.contentView?.layoutSubtreeIfNeeded()
		XCTAssertEqual(listController.incrementalUpdateCount, updatesBefore + 1)
		XCTAssertTrue(tableView.view(atColumn: 0, row: 3, makeIfNecessary: false) === existingRowCell)
		XCTAssertEqual(
			try rowText(in: tableView, row: 0, identifier: InterfaceIdentifier.headingRowTitle),
			"October 2026"
		)
		XCTAssertEqual(
			try rowText(in: tableView, row: 1, identifier: InterfaceIdentifier.documentRowTitle),
			"Kontoauszug Oktober 2026"
		)
		XCTAssertEqual(
			try rowText(in: tableView, row: 1, identifier: InterfaceIdentifier.documentRowSender),
			"Nordbank AG"
		)
		XCTAssertEqual(
			try rowText(in: tableView, row: 2, identifier: InterfaceIdentifier.headingRowTitle),
			"September 2026"
		)
		XCTAssertEqual(
			try rowText(in: tableView, row: 3, identifier: InterfaceIdentifier.documentRowTitle),
			"Haftpflichtversicherung Rechnung 5"
		)
	}

	@MainActor
	private func verifyCollectedDocumentArrives(
		in window: NSWindow,
		tableView: NSTableView,
		controller: ApplicationController
	) async throws {
		let folder = URL.temporaryDirectory.appending(
			path: "schublade_end_to_end_\(UUID().uuidString)",
			directoryHint: .isDirectory
		)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
		defer {
			try? FileManager.default.removeItem(at: folder)
		}

		let fixtureFile = repositoryRoot()
			.appending(path: "test_fixtures/collection_corpus/Downloads/Meldebescheinigung.pdf")
		try FileManager.default.copyItem(at: fixtureFile, to: folder.appending(path: "Meldebescheinigung.pdf"))

		let enrolled = try await controller.collectorCommands.enrollFolder(root: folder.path(percentEncoded: false))
		try await waitUntil("the enrolled folder awaits decision", controller) { statuses in
			guard let collector = statuses.collector else {
				return false
			}
			return collector.folders.contains { listed in
				guard listed.folder == enrolled, case .awaitingDecision = listed.admission else {
					return false
				}
				return true
			}
		}

		try await controller.collectorCommands.decideBacklog(enrolled.identifier)

		try await waitForCondition("the collected document appearing under Arriving") {
			tableView.numberOfRows == 10
		}
		window.contentView?.layoutSubtreeIfNeeded()
		XCTAssertEqual(try rowText(in: tableView, row: 0, identifier: InterfaceIdentifier.headingRowTitle), "Arriving")
		XCTAssertEqual(
			try rowText(in: tableView, row: 1, identifier: InterfaceIdentifier.documentRowTitle),
			"Processing Document"
		)
		XCTAssertEqual(
			try rowText(in: tableView, row: 2, identifier: InterfaceIdentifier.headingRowTitle),
			"October 2026"
		)
		XCTAssertEqual(
			try rowText(in: tableView, row: 3, identifier: InterfaceIdentifier.documentRowTitle),
			"Kontoauszug Oktober 2026"
		)
	}

	@MainActor
	private func verifyWindowReopen(window: NSWindow, tableView: NSTableView, controller: ApplicationController) {
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

private extension ApplicationEndToEndTests {
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
			if let view = findView(in: window.contentView, identifier: identifier, as: View.self) {
				if predicate(view) {
					return view
				}
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
	func findView<View: NSView>(
		in root: NSView?,
		identifier: String,
		as _: View.Type
	) -> View? {
		guard let root else {
			return nil
		}
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
