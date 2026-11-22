import AppKit

/// Settings' toolbar tabs. Each tab sizes the window to its content, keeping the window's top edge
/// where it is, as System Settings and every Mac application's Settings window do.
final class SettingsTabViewController: NSTabViewController {
	override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
		super.tabView(tabView, didSelect: item)
		guard let window = view.window, let size = item?.viewController?.preferredContentSize,
		      size.height > 0
		else {
			return
		}
		let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
		let top = window.frame.maxY
		window.setFrame(
			NSRect(x: window.frame.minX, y: top - frame.height, width: frame.width, height: frame.height),
			display: true,
			animate: window.isVisible
		)
	}
}
