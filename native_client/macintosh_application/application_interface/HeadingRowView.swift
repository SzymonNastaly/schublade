import AppKit

/// Plain group-heading row cell for `DocumentListViewController`.
final class HeadingRowView: NSTableCellView {
	private let titleField = NSTextField(labelWithString: "")

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		titleField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
		titleField.textColor = .secondaryLabelColor
		titleField.lineBreakMode = .byTruncatingTail
		titleField.translatesAutoresizingMaskIntoConstraints = false
		titleField.setAccessibilityIdentifier(InterfaceIdentifier.headingRowTitle)
		addSubview(titleField)

		NSLayoutConstraint.activate([
			titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
			titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
			titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func configure(title: String) {
		titleField.stringValue = title
	}
}
