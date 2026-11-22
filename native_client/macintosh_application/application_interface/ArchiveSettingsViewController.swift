import AppKit
import ApplicationBindings
import ApplicationPresentation

/// Settings > Archive: the connected host and what its token permits, Replace Token…, and Open
/// Archive in Browser. Revising documents and issuing tokens stay in the browser.
final class ArchiveSettingsViewController: NSViewController {
	private let onReplaceToken: () -> Void
	private let hostLabel = NSTextField(labelWithString: "")
	private let permissionLabel = NSTextField(wrappingLabelWithString: "")
	private let replaceToken = NSButton(title: "Replace Token…", target: nil, action: nil)
	private let openInBrowser = NSButton(title: "Open Archive in Browser", target: nil, action: nil)
	private var origin: URL?

	init(onReplaceToken: @escaping () -> Void) {
		self.onReplaceToken = onReplaceToken
		super.init(nibName: nil, bundle: nil)
		title = "Archive"
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		hostLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		permissionLabel.textColor = .secondaryLabelColor
		for button in [replaceToken, openInBrowser] {
			button.bezelStyle = .rounded
			button.target = self
		}
		replaceToken.action = #selector(replaceTokenPressed)
		openInBrowser.action = #selector(openInBrowserPressed)
		let buttons = NSStackView(views: [replaceToken, openInBrowser])
		buttons.spacing = 8
		let stack = NSStackView(views: [hostLabel, permissionLabel, buttons])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 6
		stack.setCustomSpacing(16, after: permissionLabel)
		stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
		permissionLabel.widthAnchor.constraint(equalToConstant: 360).isActive = true
		view = stack
		// A Settings window takes the size of its tab's content.
		preferredContentSize = NSSize(width: 440, height: stack.fittingSize.height)
	}

	func render(_ archive: ArchiveConnection?) {
		loadViewIfNeeded()
		switch archive {
		case let .configured(origin, host, _, permission, restricted):
			self.origin = URL(string: origin)
			hostLabel.stringValue = host
			permissionLabel.stringValue = Self.sentence(permission, restricted: restricted)
			replaceToken.isEnabled = true
			openInBrowser.isEnabled = self.origin != nil
		case .notConfigured, nil:
			origin = nil
			hostLabel.stringValue = "No archive connected"
			permissionLabel.stringValue = "Connect an archive in the Schublade window."
			replaceToken.isEnabled = false
			openInBrowser.isEnabled = false
		}
	}

	private static func sentence(_ permission: ArchivePermission, restricted: Bool) -> String {
		let reach = restricted ? " Its token sees only part of the archive." : ""
		return switch permission {
		case .readAndCollect:
			"This Mac reads the archive and adds the documents of its folders." + reach
		case .readOnly:
			"This Mac reads the archive. Its token does not add documents." + reach
		case .collectOnly:
			"This Mac adds documents. Its token does not read the archive, so the library stays empty." + reach
		}
	}

	@objc private func replaceTokenPressed() {
		onReplaceToken()
	}

	@objc private func openInBrowserPressed() {
		if let origin {
			NSWorkspace.shared.open(origin)
		}
	}
}
