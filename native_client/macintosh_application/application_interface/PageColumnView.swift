import AppKit

/// A page that is not about one document, such as a folder or Needs Attention: a vertical column
/// at most 680 points wide, centred, that scrolls when it outgrows the window.
final class PageColumnView: NSView {
	private static let widestColumn: CGFloat = 680

	let column = NSStackView()
	private let scrollView = NSScrollView()
	private let documentView = FlippedClipDocumentView()

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		column.orientation = .vertical
		column.alignment = .leading
		column.spacing = 14
		column.translatesAutoresizingMaskIntoConstraints = false
		documentView.translatesAutoresizingMaskIntoConstraints = false
		documentView.addSubview(column)

		scrollView.documentView = documentView
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = true
		scrollView.backgroundColor = .windowBackgroundColor
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		addSubview(scrollView)

		let fullWidth = column.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -56)
		// Below the window's own size, which holds at 500, so a page never resizes the window.
		fullWidth.priority = NSLayoutConstraint.Priority(490)
		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
			documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
			documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
			column.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 28),
			column.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -28),
			column.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
			column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.widestColumn),
			fullWidth,
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	/// Replaces the column's content, each view stretched to the column's width.
	func show(_ views: [NSView]) {
		for view in column.arrangedSubviews {
			column.removeArrangedSubview(view)
			view.removeFromSuperview()
		}
		for view in views {
			column.addArrangedSubview(view)
			view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
		}
	}
}
