import AppKit

/// Section header cell displayed in the sidebar outline view.
final class SidebarSectionCellView: NSTableCellView {
	private let headingField = NSTextField(labelWithString: "")

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		headingField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
		headingField.textColor = .secondaryLabelColor
		headingField.lineBreakMode = .byTruncatingTail
		headingField.translatesAutoresizingMaskIntoConstraints = false
		addSubview(headingField)

		NSLayoutConstraint.activate([
			headingField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
			headingField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
			headingField.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func configure(title: String) {
		headingField.stringValue = title
	}
}
