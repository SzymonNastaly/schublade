import AppKit
import ApplicationPresentation

/// Reader header bar showing title, subtitle, Original/Text switch, and bottom separator.
final class ReaderHeaderView: NSView {
	private let titleLabel = NSTextField(labelWithString: "")
	private let subtitleLabel = NSTextField(labelWithString: "")
	private let tabControl = NSSegmentedControl(
		labels: ["Original", "Text"],
		trackingMode: .selectOne,
		target: nil,
		action: nil
	)
	private let bottomSeparator = NSBox()
	var onTabChanged: ((ReaderTab) -> Void)?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		configureControls()
		configureLayout()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func render(detail: DocumentDetailPresentation?, hasSelection: Bool, tab: ReaderTab) {
		tabControl.selectedSegment = tab == .original ? 0 : 1
		isHidden = !hasSelection
		guard let detail else {
			titleLabel.stringValue = hasSelection ? "Loading…" : ""
			subtitleLabel.stringValue = ""
			subtitleLabel.isHidden = true
			return
		}
		titleLabel.stringValue = detail.title
		subtitleLabel.stringValue = detail.headerSubtitle
		subtitleLabel.isHidden = detail.headerSubtitle.isEmpty
	}

	private func configureControls() {
		titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular) + 2, weight: .semibold)
		titleLabel.lineBreakMode = .byTruncatingTail
		titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		titleLabel.setAccessibilityIdentifier(InterfaceIdentifier.readerTitleLabel)

		subtitleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		subtitleLabel.textColor = .secondaryLabelColor
		subtitleLabel.lineBreakMode = .byTruncatingTail
		subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		subtitleLabel.setAccessibilityIdentifier(InterfaceIdentifier.readerSubtitleLabel)

		tabControl.target = self
		tabControl.action = #selector(tabSegmentChanged)
		tabControl.selectedSegment = 0
		tabControl.setContentHuggingPriority(.required, for: .horizontal)
		tabControl.setAccessibilityIdentifier(InterfaceIdentifier.readerTabControl)

		bottomSeparator.boxType = .separator
		bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
	}

	private func configureLayout() {
		let labelsStack = NSStackView(views: [titleLabel, subtitleLabel])
		labelsStack.orientation = .vertical
		labelsStack.alignment = .leading
		labelsStack.spacing = 2
		labelsStack.translatesAutoresizingMaskIntoConstraints = false
		tabControl.translatesAutoresizingMaskIntoConstraints = false

		addSubview(labelsStack)
		addSubview(tabControl)
		addSubview(bottomSeparator)

		NSLayoutConstraint.activate([
			heightAnchor.constraint(equalToConstant: 56),
			labelsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
			labelsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
			labelsStack.trailingAnchor.constraint(lessThanOrEqualTo: tabControl.leadingAnchor, constant: -16),
			tabControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
			tabControl.centerYAnchor.constraint(equalTo: centerYAnchor),
			bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
			bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
			bottomSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	@objc private func tabSegmentChanged() {
		onTabChanged?(tabControl.selectedSegment == 1 ? .text : .original)
	}
}
