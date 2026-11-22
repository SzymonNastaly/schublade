import AppKit

/// Horizontal wrapping container for tag chip buttons inside a fixed-width inspector column.
final class WrappingFlowView: NSView {
	private static let fallbackWidth: CGFloat = 218
	private static let itemSpacing: CGFloat = 6
	private static let rowSpacing: CGFloat = 6

	private var arrangedSubviews: [NSView] = []
	private var lastMeasuredHeight: CGFloat = 0

	override var isFlipped: Bool {
		true
	}

	func setViews(_ views: [NSView]) {
		for subview in arrangedSubviews {
			subview.removeFromSuperview()
		}
		arrangedSubviews = views
		for subview in views {
			addSubview(subview)
		}
		needsLayout = true
		invalidateIntrinsicContentSize()
	}

	override func layout() {
		super.layout()
		let width = bounds.width > 1 ? bounds.width : Self.fallbackWidth
		let totalHeight = placeItems(withinWidth: width, applyFrames: true)
		if abs(totalHeight - lastMeasuredHeight) > 0.5 {
			lastMeasuredHeight = totalHeight
			invalidateIntrinsicContentSize()
		}
	}

	override var intrinsicContentSize: NSSize {
		let width = bounds.width > 1 ? bounds.width : Self.fallbackWidth
		let totalHeight = placeItems(withinWidth: width, applyFrames: false)
		return NSSize(width: NSView.noIntrinsicMetric, height: totalHeight)
	}

	private func placeItems(withinWidth availableWidth: CGFloat, applyFrames: Bool) -> CGFloat {
		var cursorX: CGFloat = 0
		var cursorY: CGFloat = 0
		var lineHeight: CGFloat = 0

		for item in arrangedSubviews {
			let size = item.intrinsicContentSize
			let itemWidth = min(size.width, availableWidth)
			if cursorX > 0, cursorX + itemWidth > availableWidth {
				cursorX = 0
				cursorY += lineHeight + Self.rowSpacing
				lineHeight = 0
			}
			if applyFrames {
				item.frame = NSRect(x: cursorX, y: cursorY, width: itemWidth, height: size.height)
			}
			cursorX += itemWidth + Self.itemSpacing
			lineHeight = max(lineHeight, size.height)
		}

		return arrangedSubviews.isEmpty ? 0 : cursorY + lineHeight
	}
}
