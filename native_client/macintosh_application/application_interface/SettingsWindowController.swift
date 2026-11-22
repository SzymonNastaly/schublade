import AppKit
import ApplicationBindings

/// The Settings window: toolbar tabs as every Mac application has them, opened with Command-Comma.
final class SettingsWindowController: NSWindowController {
	private let archive: ArchiveSettingsViewController

	init(loginItem: LoginItem, statusItem: NSStatusItem, onReplaceToken: @escaping () -> Void) {
		archive = ArchiveSettingsViewController(onReplaceToken: onReplaceToken)
		let tabs = NSTabViewController()
		tabs.tabStyle = .toolbar
		let general = GeneralSettingsViewController(loginItem: loginItem, statusItem: statusItem)
		for (controller, symbol) in [(general as NSViewController, "gearshape"), (archive, "archivebox")] {
			let item = NSTabViewItem(viewController: controller)
			item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: controller.title)
			tabs.addTabViewItem(item)
		}
		let window = NSWindow(contentViewController: tabs)
		window.styleMask = [.titled, .closable]
		window.toolbarStyle = .preference
		window.title = "Settings"
		window.isReleasedWhenClosed = false
		super.init(window: window)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func render(_ archiveConnection: ArchiveConnection?) {
		archive.render(archiveConnection)
	}

	func present() {
		window?.center()
		showWindow(nil)
		window?.makeKeyAndOrderFront(nil)
		NSApp.activate()
	}
}
