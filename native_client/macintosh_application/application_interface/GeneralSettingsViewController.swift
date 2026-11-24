import AppKit

/// What Settings > General turns on and off of the menu bar item; `NSStatusItem` keeps its own
/// visibility under its autosave name.
public protocol StatusItemVisibility: AnyObject {
	var isVisible: Bool { get set }
}

extension NSStatusItem: StatusItemVisibility {}

/// Settings > General: Open at Login, read from the system each time the tab appears, and Show in
/// Menu Bar.
public final class GeneralSettingsViewController: NSViewController {
	private let loginItem: LoginItem
	private let statusItem: any StatusItemVisibility
	private let openAtLogin = NSButton(checkboxWithTitle: "Open Schublade at login", target: nil, action: nil)
	private let showInMenuBar = NSButton(checkboxWithTitle: "Show Schublade in the menu bar", target: nil, action: nil)

	public init(loginItem: LoginItem, statusItem: any StatusItemVisibility) {
		self.loginItem = loginItem
		self.statusItem = statusItem
		super.init(nibName: nil, bundle: nil)
		title = "General"
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override public func loadView() {
		openAtLogin.target = self
		openAtLogin.action = #selector(openAtLoginChanged)
		showInMenuBar.target = self
		showInMenuBar.action = #selector(showInMenuBarChanged)
		let note = NSTextField(wrappingLabelWithString: "Schublade collects the folders on this Mac while it is "
			+ "open, also with its window closed.")
		note.font = NSFont.preferredFont(forTextStyle: .subheadline)
		note.textColor = .secondaryLabelColor
		view = SettingsPaneLayout.pane([
			.init(label: "Startup:", content: openAtLogin),
			.init(label: nil, content: note),
			.init(label: "Menu bar:", content: showInMenuBar, spacingAbove: 8),
		])
		// A Settings window takes the size of its tab's content.
		preferredContentSize = view.fittingSize
	}

	override public func viewWillAppear() {
		super.viewWillAppear()
		openAtLogin.state = loginItem.isEnabled ? .on : .off
		showInMenuBar.state = statusItem.isVisible ? .on : .off
	}

	@objc private func openAtLoginChanged() {
		loginItem.setEnabled(openAtLogin.state == .on)
		openAtLogin.state = loginItem.isEnabled ? .on : .off
	}

	@objc private func showInMenuBarChanged() {
		statusItem.isVisible = showInMenuBar.state == .on
	}
}
