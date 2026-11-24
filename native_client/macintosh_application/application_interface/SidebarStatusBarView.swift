import AppKit
import ApplicationPresentation
import LibraryPresentation

/// The sidebar's status line: the connection's state and the copy's progress in one line. A click
/// synchronizes, or opens the replace form while the archive refuses the token.
final class SidebarStatusBarView: NSView {
	private let button = NSButton()
	private let symbolView = NSImageView()
	private let statusLabel = NSTextField(labelWithString: "")
	private let progressIndicator = NSProgressIndicator()
	private var onPressHandler: (() -> Void)?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		configureControls()
		configureLayout()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func render(_ presentation: StatusLinePresentation, onPress: @escaping () -> Void) {
		onPressHandler = onPress
		symbolView.image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: nil)
		symbolView.contentTintColor = InterfacePalette.statusLineSymbol(presentation.tone)
		statusLabel.stringValue = presentation.text
		statusLabel.textColor = presentation.tone == .attention ? InterfacePalette.attention : .secondaryLabelColor
		button.isEnabled = presentation.allowsSynchronize || presentation.allowsTokenReplacement
		button.toolTip = if presentation.allowsTokenReplacement {
			"Replace Token…"
		} else if presentation.allowsSynchronize {
			"Synchronize Now"
		} else {
			nil
		}

		if let progress = presentation.progress {
			progressIndicator.doubleValue = progress
			progressIndicator.isHidden = false
		} else {
			progressIndicator.isHidden = true
		}
	}

	private func configureControls() {
		button.title = ""
		button.isBordered = false
		button.target = self
		button.action = #selector(statusBarPressed)
		button.translatesAutoresizingMaskIntoConstraints = false
		button.setAccessibilityIdentifier(InterfaceIdentifier.sidebarStatusButton)

		symbolView.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .subheadline)
		symbolView.setContentHuggingPriority(.required, for: .horizontal)
		symbolView.setContentCompressionResistancePriority(.required, for: .horizontal)

		statusLabel.font = NSFont.preferredFont(forTextStyle: .subheadline)
		statusLabel.lineBreakMode = .byTruncatingTail
		statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		statusLabel.setAccessibilityIdentifier(InterfaceIdentifier.sidebarStatusLabel)

		progressIndicator.isIndeterminate = false
		progressIndicator.minValue = 0
		progressIndicator.maxValue = 1
		progressIndicator.controlSize = .small
		progressIndicator.style = .bar
		progressIndicator.isHidden = true
		progressIndicator.setAccessibilityIdentifier(InterfaceIdentifier.sidebarStatusProgress)
	}

	private func configureLayout() {
		let topLine = NSStackView(views: [symbolView, statusLabel])
		topLine.orientation = .horizontal
		topLine.alignment = .centerY
		topLine.spacing = 6

		let stack = NSStackView(views: [topLine, progressIndicator])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 4
		stack.translatesAutoresizingMaskIntoConstraints = false

		addSubview(stack)
		addSubview(button)

		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
			stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
			topLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
			progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
			button.leadingAnchor.constraint(equalTo: leadingAnchor),
			button.trailingAnchor.constraint(equalTo: trailingAnchor),
			button.topAnchor.constraint(equalTo: topAnchor),
			button.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	@objc private func statusBarPressed() {
		onPressHandler?()
	}
}
