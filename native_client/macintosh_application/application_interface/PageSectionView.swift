import AppKit

/// A titled group on a page, drawn as System Settings draws its groups: a rounded box in the
/// control background with a hairline border, which a box keeps right in both appearances.
final class PageSectionView: NSBox {
	let content = NSStackView()

	init(title: String?, symbolName: String? = nil, symbolColor: NSColor = .secondaryLabelColor) {
		super.init(frame: .zero)
		boxType = .custom
		titlePosition = .noTitle
		cornerRadius = 10
		borderWidth = 0.5
		borderColor = .separatorColor
		fillColor = .controlBackgroundColor
		contentViewMargins = NSSize(width: 16, height: 14)

		content.orientation = .vertical
		content.alignment = .leading
		content.spacing = 8
		content.translatesAutoresizingMaskIntoConstraints = false
		if let title {
			content.addArrangedSubview(Self.heading(title, symbolName: symbolName, symbolColor: symbolColor))
			content.setCustomSpacing(10, after: content.arrangedSubviews[0])
		}
		guard let box = contentView else {
			return
		}
		box.addSubview(content)
		NSLayoutConstraint.activate([
			content.topAnchor.constraint(equalTo: box.topAnchor),
			content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
			content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
			content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	/// Adds a view that spans the section's width.
	func append(_ view: NSView) {
		content.addArrangedSubview(view)
		view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
	}

	private static func heading(_ title: String, symbolName: String?, symbolColor: NSColor) -> NSView {
		let label = NSTextField(labelWithString: title)
		label.font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
		guard let symbolName, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
			return label
		}
		let symbol = NSImageView(image: image)
		symbol.contentTintColor = symbolColor
		symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
		let row = NSStackView(views: [symbol, label])
		row.spacing = 6
		return row
	}
}
