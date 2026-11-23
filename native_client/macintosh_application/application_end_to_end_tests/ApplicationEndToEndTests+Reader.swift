import AppKit
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

	/// The reader's Original and Text switch between the page and the extracted text.
	func verifyReaderTabGroup(in window: NSWindow) async throws {
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
}
