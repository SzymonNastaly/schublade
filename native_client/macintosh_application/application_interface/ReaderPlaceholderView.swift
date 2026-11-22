import AppKit

/// Centered placeholder screen displayed by the reader when no original or text is available.
final class ReaderPlaceholderView: NSView {
	private let titleLabel = NSTextField(labelWithString: "")
	private let detailLabel = NSTextField(wrappingLabelWithString: "")
	private let actionButton = NSButton()
	private var onAction: (() -> Void)?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		configureControls()
		configureLayout()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func render(title: String, detail: String, buttonTitle: String?, onAction: (() -> Void)?) {
		self.onAction = onAction
		titleLabel.stringValue = title
		detailLabel.stringValue = detail
		detailLabel.isHidden = detail.isEmpty
		if let buttonTitle, onAction != nil {
			actionButton.title = buttonTitle
			actionButton.isHidden = false
		} else {
			actionButton.isHidden = true
		}
	}

	private func configureControls() {
		titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular) + 2, weight: .semibold)
		titleLabel.textColor = .secondaryLabelColor
		titleLabel.alignment = .center
		titleLabel.setAccessibilityIdentifier(InterfaceIdentifier.readerPlaceholderTitle)

		detailLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
		detailLabel.textColor = .secondaryLabelColor
		detailLabel.alignment = .center
		detailLabel.setAccessibilityIdentifier(InterfaceIdentifier.readerPlaceholderDetail)

		actionButton.bezelStyle = .rounded
		actionButton.target = self
		actionButton.action = #selector(actionPressed)
		actionButton.isHidden = true
		actionButton.setAccessibilityIdentifier(InterfaceIdentifier.readerPlaceholderAction)
	}

	private func configureLayout() {
		let stack = NSStackView(views: [titleLabel, detailLabel, actionButton])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 6
		stack.setCustomSpacing(12, after: detailLabel)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)

		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
			detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
		])
	}

	@objc private func actionPressed() {
		onAction?()
	}
}
