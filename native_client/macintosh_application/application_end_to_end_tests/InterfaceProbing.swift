import AppKit
import ApplicationBindings
import ApplicationPresentation
import PDFKit
import XCTest
@testable import ApplicationInterface

/// Finding the running application's views by their identifiers and waiting for what the
/// test expects, so each step of the end-to-end test reads as what a person does.
protocol InterfaceProbing {}

extension InterfaceProbing {
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
