import AppKit

/// The inspector gives way before the window narrows below what the four parts of the workspace
/// need, so the window's minimum holds.
extension MainWindowController {
	func windowWillResize(_: NSWindow, to frameSize: NSSize) -> NSSize {
		workspaceController?.accommodate(windowWidth: frameSize.width)
		return frameSize
	}

	/// A frame set without a live resize, by tiling or Accessibility, asks no permission first.
	func windowDidResize(_: Notification) {
		window.map { workspaceController?.accommodate(windowWidth: $0.frame.width) }
	}
}
