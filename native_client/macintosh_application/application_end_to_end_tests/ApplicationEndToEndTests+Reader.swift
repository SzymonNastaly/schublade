import AppKit
import PDFKit
import XCTest
@testable import ApplicationInterface

/// The inspector's facts and the reader's tabs, as a person reaches them.
@MainActor
extension ApplicationEndToEndTests {
	/// A click on the amount copies its plain number and shows "Copied" in its place.
	func verifyAmountCopies(in window: NSWindow) async throws {
		let amountRow = try await waitForView(
			"the inspector's amount",
			in: window,
			identifier: "inspector.field.amount",
			as: InspectorFieldRowView.self
		)
		XCTAssertEqual(amountRow.displayValue, "72.09 EUR")
		amountRow.performClick(nil)
		XCTAssertEqual(NSPasteboard.general.string(forType: .string), "72.09")
		XCTAssertTrue(amountRow.showsCopied)
		try await waitForCondition("the amount reads its value again") { !amountRow.showsCopied }
	}

	/// The toolbar's Original and Text switch the reader, and View's items follow them.
	func verifyReaderTabGroup(in window: NSWindow) async throws {
		let group = try XCTUnwrap(window.toolbar?.items.first {
			$0.itemIdentifier.rawValue == "schublade.readerTab"
		} as? NSToolbarItemGroup)
		XCTAssertTrue(group.isEnabled)
		XCTAssertEqual(group.selectedIndex, 0)
		group.selectedIndex = 1
		try NSApp.sendAction(XCTUnwrap(group.action), to: group.target, from: group)

		let textView = try await waitForView(
			"extracted text in reader Text tab",
			in: window,
			identifier: InterfaceIdentifier.readerTextView,
			as: NSTextView.self
		) { $0.enclosingScrollView?.isHidden == false && $0.string.contains("Rechnung Nummer 5") }
		XCTAssertTrue(textView.string.contains("Rechnung Nummer 5 für Haftpflichtversicherung."))
		XCTAssertEqual(group.selectedIndex, 1)
		try await verifyFindNextSelectsTheMatch(in: textView)

		let workspace = try XCTUnwrap(
			(NSApp.delegate as? ApplicationDelegate)?.controller.mainWindowController.workspaceController
		)
		let textItem = NSMenuItem(
			title: "Text",
			action: #selector(LibraryWorkspaceViewController.showExtractedTextRepresentation(_:)),
			keyEquivalent: "2"
		)
		XCTAssertTrue(workspace.validateMenuItem(textItem))
		XCTAssertEqual(textItem.state, .on)

		workspace.showOriginalRepresentation(nil)
		try await waitForCondition("Command-1 shows the original and the group follows") {
			pdfView(in: window)?.isHidden == false && group.selectedIndex == 0
		}
	}

	/// A search marks its word in the text, and Find Next and Find Previous select it.
	func verifyFindNextSelectsTheMatch(in textView: NSTextView) async throws {
		let windowController = try XCTUnwrap((NSApp.delegate as? ApplicationDelegate)?.controller.mainWindowController)
		let match = try NSRange(XCTUnwrap(textView.string.range(of: "Haftpflichtversicherung")), in: textView.string)
		windowController.setSearchText("Haftpflichtversicherung")
		try await waitForCondition("the text marks the searched word") {
			textView.textStorage?.attribute(.backgroundColor, at: match.location, effectiveRange: nil) != nil
		}
		let findNext = NSMenuItem(
			title: "Find Next",
			action: #selector(MainWindowController.findNextMatch(_:)),
			keyEquivalent: "g"
		)
		XCTAssertTrue(windowController.validateMenuItem(findNext))
		windowController.findNextMatch(nil)
		XCTAssertEqual(textView.selectedRange(), match)
		textView.setSelectedRange(NSRange(location: 0, length: 0))
		windowController.findPreviousMatch(nil)
		XCTAssertEqual(textView.selectedRange(), match)
		windowController.setSearchText("")
		XCTAssertFalse(windowController.validateMenuItem(findNext))
	}

	func pdfView(in window: NSWindow) -> PDFView? {
		findView(in: window.contentView, identifier: InterfaceIdentifier.readerPortableDocumentView, as: PDFView.self)
	}
}
