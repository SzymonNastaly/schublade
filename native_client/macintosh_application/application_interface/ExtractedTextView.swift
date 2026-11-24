import AppKit

/// The reader's text in a column of at most 680 points, centred, with 24 points on every side. A
/// table wider than the column widens it as far as the reader allows, so its rows stay unwrapped.
final class ExtractedTextView: NSTextView {
	private static let readableColumnWidth: CGFloat = 680
	private static let margin: CGFloat = 24

	/// The width the widest table row of the shown text needs.
	var widestTableRow: CGFloat = 0 {
		didSet {
			placeColumn(in: bounds.width)
		}
	}

	func configureColumn() {
		textContainer?.widthTracksTextView = false
		textContainer?.lineFragmentPadding = 0
		placeColumn(in: bounds.width)
	}

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		placeColumn(in: newSize.width)
	}

	private func placeColumn(in width: CGFloat) {
		let available = max(0, width - 2 * Self.margin)
		let column = min(available, max(Self.readableColumnWidth, widestTableRow))
		let inset = NSSize(width: (Self.margin + (available - column) / 2).rounded(.down), height: Self.margin)
		if textContainerInset != inset {
			textContainerInset = inset
		}
		if let container = textContainer, container.size.width != column {
			container.size = NSSize(width: column, height: CGFloat.greatestFiniteMagnitude)
		}
	}
}
