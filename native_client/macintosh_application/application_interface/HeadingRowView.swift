import AppKit

/// A month's heading, or Arriving and the two sections of a search, floating over the rows under it.
/// Its text starts where the rows' pictures do.
final class HeadingRowView: NSTableCellView {
	private static let titleFont = NSFont.systemFont(
		ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
		weight: .semibold
	)

	/// The heading's one height, from its font's line height.
	static let rowHeight: CGFloat = ceil(NSLayoutManager().defaultLineHeight(for: titleFont) + 12)

	private let titleField = NSTextField(labelWithString: "")

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		titleField.font = Self.titleFont
		titleField.textColor = .secondaryLabelColor
		titleField.lineBreakMode = .byTruncatingTail
		titleField.translatesAutoresizingMaskIntoConstraints = false
		titleField.setAccessibilityIdentifier(InterfaceIdentifier.headingRowTitle)
		addSubview(titleField)

		NSLayoutConstraint.activate([
			titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
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
