import AppKit
import XCTest
@testable import ApplicationInterface

/// The window's parts as its width and a new split view change them.
@MainActor
extension ApplicationEndToEndTests {
	/// The inspector gives way to a window narrowed to 1,070 points, within the system's allowance
	/// of the parts' minimums, comes back at 1,100 without the person's choice having changed, and
	/// stays once a person shows it in a window too narrow for it.
	func verifyInspectorGivesWayAndReturns(in window: NSWindow, controller: ApplicationController) async throws {
		let windowController = controller.mainWindowController
		let inspector = try XCTUnwrap(windowController.workspaceController?.splitViewItems.last)
		XCTAssertEqual(window.contentMinSize, NSSize(width: 900, height: 560))
		let fullFrame = window.frame
		func setWidth(_ width: CGFloat) {
			var frame = window.frame
			frame.size.width = width
			window.setFrame(frame, display: true)
		}

		setWidth(1070)
		try await waitForCondition("the inspector gives way at 1,070 points") { inspector.isCollapsed }
		XCTAssertTrue(windowController.navigation.inspectorVisible)
		setWidth(1100)
		try await waitForCondition("the inspector returns at 1,100 points") { !inspector.isCollapsed }

		setWidth(1070)
		try await waitForCondition("the inspector gives way again") { inspector.isCollapsed }
		windowController.workspaceController?.toggleInspector(nil)
		try await waitForCondition("Show Inspector widens the window") { window.frame.width >= 1075 }
		try await Task.sleep(for: .milliseconds(300))
		XCTAssertFalse(inspector.isCollapsed)
		window.setFrame(fullFrame, display: true)
	}

	/// Replace Token… builds a new workspace, and every section of the toolbar follows its split view.
	func verifyToolbarFollowsANewSplitView(in window: NSWindow, controller: ApplicationController) async throws {
		let windowController = controller.mainWindowController
		weak var replacedWorkspace: LibraryWorkspaceViewController?
		replacedWorkspace = windowController.workspaceController
		XCTAssertNotNil(replacedWorkspace)
		windowController.beginTokenReplacement()
		let cancel = try await waitForView(
			"the replace form's Cancel",
			in: window,
			identifier: InterfaceIdentifier.connectionCancelButton,
			as: NSButton.self
		)
		cancel.performClick(nil)
		try await waitForCondition("a new workspace with its toolbar") {
			windowController.workspaceController.map { $0 !== replacedWorkspace } == true && window.toolbar != nil
		}
		let splitView = try XCTUnwrap(windowController.workspaceController?.splitView)
		let separators = window.toolbar?.items.compactMap { $0 as? NSTrackingSeparatorToolbarItem } ?? []
		XCTAssertEqual(separators.count, 3)
		XCTAssertEqual(separators.filter { $0.splitView !== splitView }.map(\.itemIdentifier.rawValue), [])
	}
}
