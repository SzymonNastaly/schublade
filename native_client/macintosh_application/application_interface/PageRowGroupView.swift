import AppKit

/// A list on a page as a pane of System Settings draws one: a heading, a rounded box of rows with
/// hairlines between them, and an optional note under the box.
final class PageRowGroupView: NSStackView {
	private let rows = NSStackView()

	init(heading: String) {
		super.init(frame: .zero)
		orientation = .vertical
		alignment = .leading
		spacing = 6

		let title = NSTextField(labelWithString: heading)
		title.font = NSFont.preferredFont(forTextStyle: .headline)
		addArrangedSubview(title)

		rows.orientation = .vertical
		rows.alignment = .leading
		rows.spacing = 0
		rows.translatesAutoresizingMaskIntoConstraints = false
		let box = NSBox()
		box.boxType = .custom
		box.titlePosition = .noTitle
		box.cornerRadius = 10
		box.borderWidth = 0.5
		box.borderColor = .separatorColor
		box.fillColor = .controlBackgroundColor
		box.contentViewMargins = .zero
		if let content = box.contentView {
			content.addSubview(rows)
			NSLayoutConstraint.activate([
				rows.topAnchor.constraint(equalTo: content.topAnchor),
				rows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
				rows.trailingAnchor.constraint(equalTo: content.trailingAnchor),
				rows.bottomAnchor.constraint(equalTo: content.bottomAnchor),
			])
		}
		addArrangedSubview(box)
		box.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	/// Adds a row under a hairline, spanning the box's width inside its margins.
	func appendRow(_ row: NSView) {
		if !rows.arrangedSubviews.isEmpty {
			let hairline = NSBox()
			hairline.boxType = .separator
			let inset = NSStackView(views: [hairline])
			inset.distribution = .fill
			inset.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
			rows.addArrangedSubview(inset)
			inset.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
		}
		let padded = NSStackView(views: [row])
		padded.distribution = .fill
		padded.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
		rows.addArrangedSubview(padded)
		padded.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
	}

	/// A sentence under the box, such as where the documents of a row can be settled.
	func appendNote(_ text: String) {
		let note = NSTextField(wrappingLabelWithString: text)
		note.font = NSFont.preferredFont(forTextStyle: .footnote)
		note.textColor = .secondaryLabelColor
		addArrangedSubview(note)
		note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
	}
}
