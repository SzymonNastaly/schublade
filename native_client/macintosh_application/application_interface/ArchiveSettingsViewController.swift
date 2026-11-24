import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// Settings > Archive: the connected host, whether the copy is current, what the token permits,
/// Replace Token…, and Open Archive in Browser. Revising documents and issuing tokens stay in the
/// browser.
public final class ArchiveSettingsViewController: NSViewController {
	private let onReplaceToken: () -> Void
	private let hostLabel = NSTextField(labelWithString: "")
	private let statusSymbol = NSImageView()
	private let statusLabel = NSTextField(labelWithString: "")
	private lazy var statusRow = NSStackView(views: [statusSymbol, statusLabel])
	private let permissionLabel = NSTextField(wrappingLabelWithString: "")
	private let replaceToken = NSButton(title: "Replace Token…", target: nil, action: nil)
	private let openInBrowser = NSButton(title: "Open Archive in Browser", target: nil, action: nil)
	private var origin: URL?

	public init(onReplaceToken: @escaping () -> Void) {
		self.onReplaceToken = onReplaceToken
		super.init(nibName: nil, bundle: nil)
		title = "Archive"
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override public func loadView() {
		hostLabel.font = NSFont.preferredFont(forTextStyle: .headline)
		hostLabel.lineBreakMode = .byTruncatingMiddle
		statusSymbol.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .subheadline)
		statusLabel.font = NSFont.preferredFont(forTextStyle: .subheadline)
		statusRow.orientation = .horizontal
		statusRow.spacing = 4
		statusRow.detachesHiddenViews = true
		permissionLabel.font = NSFont.preferredFont(forTextStyle: .body)
		for button in [replaceToken, openInBrowser] {
			button.bezelStyle = .push
			button.target = self
		}
		replaceToken.action = #selector(replaceTokenPressed)
		openInBrowser.action = #selector(openInBrowserPressed)
		let buttons = NSStackView(views: [replaceToken, openInBrowser])
		buttons.spacing = 8
		view = SettingsPaneLayout.pane([
			.init(label: "Archive:", content: hostLabel),
			.init(label: nil, content: statusRow),
			.init(label: "Token:", content: permissionLabel, spacingAbove: 8),
			.init(label: nil, content: buttons, spacingAbove: 4),
		])
	}

	/// The status line is the sidebar's, without the uploads, which are no fact of the archive.
	public func render(_ statuses: ApplicationStatuses?, context: ApplicationWordingContext) {
		loadViewIfNeeded()
		switch statuses?.library?.archive {
		case let .configured(origin, host, _, permission, restricted):
			self.origin = URL(string: origin)
			hostLabel.stringValue = host
			permissionLabel.stringValue = Self.sentence(permission, restricted: restricted)
			replaceToken.isEnabled = true
			openInBrowser.isEnabled = self.origin != nil
			if let statuses {
				let line = StatusLinePresentation.resolve(statuses: statuses, context: context, includesUploads: false)
				statusSymbol.image = NSImage(systemSymbolName: line.symbolName, accessibilityDescription: nil)
				statusSymbol.contentTintColor = InterfacePalette.statusLineSymbol(line.tone)
				statusLabel.stringValue = line.text
				statusLabel.textColor = line.tone == .attention ? InterfacePalette.attention : .secondaryLabelColor
			}
			statusRow.isHidden = false
		case .notConfigured, nil:
			origin = nil
			hostLabel.stringValue = "No archive connected"
			permissionLabel.stringValue = "Connect an archive in the Schublade window."
			statusRow.isHidden = true
			replaceToken.isEnabled = false
			openInBrowser.isEnabled = false
		}
		preferredContentSize = view.fittingSize
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
