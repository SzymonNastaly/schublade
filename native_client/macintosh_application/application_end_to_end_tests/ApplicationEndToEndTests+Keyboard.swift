import AppKit
import PDFKit
import XCTest
@testable import ApplicationInterface

/// What a person reaches with the keyboard alone: the results from the search field, the parts of
/// the window by Tab, and a row's menu without a click.
@MainActor
extension ApplicationEndToEndTests {
	/// Down takes the keyboard from the search field to the list and selects the first result, the
	/// row's menu opens for the selected row without a click, and Escape clears the search and leaves
	/// the keyboard with the list.
	func verifySearchFieldHandsTheKeyboardToTheList(
		_ searchField: NSSearchField,
		tableView: NSTableView,
		in window: NSWindow
	) async throws {
		let delegate = try XCTUnwrap(searchField.delegate)
		let fieldEditor = NSTextView()
		try await waitForCondition("the results hold no selection") { tableView.selectedRow < 0 }

		XCTAssertEqual(
			delegate.control?(searchField, textView: fieldEditor, doCommandBy: #selector(NSResponder.moveDown(_:))),
			true
		)
		XCTAssertTrue(window.firstResponder === tableView)
		XCTAssertEqual(tableView.selectedRow, 1)
		_ = try await waitForView(
			"the first result in the inspector",
			in: window,
			identifier: InterfaceIdentifier.inspectorTitleLabel,
			as: NSTextField.self
		) { $0.stringValue == "Kontoauszug Oktober 2026" }

		let rowMenu = NSMenu()
		try XCTUnwrap(tableView.menu?.delegate).menuNeedsUpdate?(rowMenu)
		XCTAssertEqual(rowMenu.items.last?.title, "Open in Browser")

		XCTAssertEqual(
			delegate.control?(
				searchField,
				textView: fieldEditor,
				doCommandBy: #selector(NSResponder.cancelOperation(_:))
			),
			true
		)
		XCTAssertEqual(searchField.stringValue, "")
		try await waitForCondition("Escape restores the full list") { tableView.numberOfRows == 8 }
		XCTAssertTrue(window.firstResponder === tableView)
	}

	/// Tab from the list reaches the reader's shown pane, passes over the hidden one, reaches the
	/// inspector's rows while the Mac lets Tab reach every control, and returns to the sidebar.
	func verifyTabReaches(_ shownPane: NSView, from tableView: NSTableView) throws {
		var reached: [NSView] = []
		var next = tableView.nextValidKeyView
		while let view = next, view !== tableView, reached.count < 50 {
			reached.append(view)
			next = view.nextValidKeyView
		}
		XCTAssertTrue(reached.first === shownPane)
		XCTAssertTrue(reached.last is NSOutlineView)
		XCTAssertFalse(reached.contains { $0.isHiddenOrHasHiddenAncestor })
		XCTAssertEqual(reached.contains { $0 is InspectorFieldRowView }, NSApp.isFullKeyboardAccessEnabled)
	}
}
