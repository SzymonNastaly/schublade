import AppKit
import ApplicationPresentation

/// The Settings window: toolbar tabs as every Mac application has them, opened with Command-Comma.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
	private let archive: ArchiveSettingsViewController

	init(
		loginItem: LoginItem,
		statusItem: NSStatusItem,
		storage: StorageSettingsViewController,
		onReplaceToken: @escaping () -> Void
	) {
		archive = ArchiveSettingsViewController(onReplaceToken: onReplaceToken)
		let tabs = SettingsTabViewController()
		tabs.tabStyle = .toolbar
		let general = GeneralSettingsViewController(loginItem: loginItem, statusItem: statusItem)
		let tabsWithSymbols: [(NSViewController, String)] = [
			(general, "gearshape"),
			(archive, "archivebox"),
			(storage, "internaldrive"),
		]
		for (controller, symbol) in tabsWithSymbols {
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
		window.delegate = self
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func windowWillClose(_: Notification) {
		ActivationPolicy.becomeAccessoryUnlessAnotherWindowShows(besides: window)
	}

	func render(_ statuses: ApplicationStatuses?, context: ApplicationWordingContext) {
		archive.render(statuses, context: context)
	}

	func present() {
		// Settings opened from the menu bar item with the main window closed still gets a Dock icon.
		ActivationPolicy.becomeRegular()
		window?.center()
		showWindow(nil)
		window?.makeKeyAndOrderFront(nil)
		NSApp.activate()
	}
}
