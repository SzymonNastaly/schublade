import AppKit

/// Full-pane detail view for workspace states that replace the document list, reader, and inspector.
final class WorkspaceNoticeViewController: NSViewController {
	private let titleLabel = NSTextField(labelWithString: "")
	private let detailLabel = NSTextField(wrappingLabelWithString: "")
	private let actionButton = NSButton()
	private var onAction: (() -> Void)?

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 600))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		configureControls()
		configureLayout()
	}

	func render(title: String, detail: String, actionTitle: String?, onAction: (() -> Void)?) {
		self.onAction = onAction
		titleLabel.stringValue = title
		detailLabel.stringValue = detail
		detailLabel.isHidden = detail.isEmpty
		if let actionTitle, onAction != nil {
			actionButton.title = actionTitle
			actionButton.isHidden = false
		} else {
			actionButton.isHidden = true
		}
	}

	private func configureControls() {
		titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular) + 4, weight: .semibold)
		titleLabel.alignment = .center

		detailLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
		detailLabel.textColor = .secondaryLabelColor
		detailLabel.alignment = .center
		detailLabel.setAccessibilityIdentifier(InterfaceIdentifier.workspaceNoticeMessage)

		actionButton.bezelStyle = .rounded
		actionButton.target = self
		actionButton.action = #selector(actionPressed)
		actionButton.isHidden = true
		actionButton.setAccessibilityIdentifier(InterfaceIdentifier.workspaceNoticeActionButton)
	}

	private func configureLayout() {
		let stack = NSStackView(views: [titleLabel, detailLabel, actionButton])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 8
		stack.setCustomSpacing(14, after: detailLabel)
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)

		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
			stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
			detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
		])
	}

	@objc private func actionPressed() {
		onAction?()
	}
}
