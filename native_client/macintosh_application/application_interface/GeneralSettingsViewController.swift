import AppKit

/// Settings > General: Open at Login, read from the system each time the tab appears, and Show in
/// Menu Bar, which AppKit keeps for the status item under its autosave name.
final class GeneralSettingsViewController: NSViewController {
	private let loginItem: LoginItem
	private let statusItem: NSStatusItem
	private let openAtLogin = NSButton(checkboxWithTitle: "Open Schublade at login", target: nil, action: nil)
	private let showInMenuBar = NSButton(checkboxWithTitle: "Show Schublade in the menu bar", target: nil, action: nil)

	init(loginItem: LoginItem, statusItem: NSStatusItem) {
		self.loginItem = loginItem
		self.statusItem = statusItem
		super.init(nibName: nil, bundle: nil)
		title = "General"
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		openAtLogin.target = self
		openAtLogin.action = #selector(openAtLoginChanged)
		showInMenuBar.target = self
		showInMenuBar.action = #selector(showInMenuBarChanged)
		let note = NSTextField(wrappingLabelWithString: "Folders on this Mac are collected while Schublade is open, "
			+ "also with its window closed.")
		note.textColor = .secondaryLabelColor
		note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		let stack = NSStackView(views: [openAtLogin, note, showInMenuBar])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 8
		stack.setCustomSpacing(16, after: note)
		stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
		note.widthAnchor.constraint(equalToConstant: 360).isActive = true
		view = stack
		// A Settings window takes the size of its tab's content.
		preferredContentSize = NSSize(width: 440, height: stack.fittingSize.height)
	}

	override func viewWillAppear() {
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
