import AppKit
import ApplicationBindings

/// One tag in the inspector: its name in the label colour on a fill without a border. A click
/// lists the tag's documents.
final class TagChipButton: NSButton {
	private let tagScope: NamedScope
	private let onSelectScope: (NamedScope) -> Void

	init(tagScope: NamedScope, onSelectScope: @escaping (NamedScope) -> Void) {
		self.tagScope = tagScope
		self.onSelectScope = onSelectScope
		super.init(frame: .zero)

		isBordered = false
		attributedTitle = NSAttributedString(string: tagScope.name, attributes: [
			.font: NSFont.preferredFont(forTextStyle: .subheadline),
			.foregroundColor: NSColor.labelColor,
		])
		setButtonType(.momentaryChange)
		target = self
		action = #selector(tagPressed)
		toolTip = "Show the documents tagged \(tagScope.name)"
		setAccessibilityIdentifier("inspector.tag.\(tagScope.name)")
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func draw(_ dirtyRect: NSRect) {
		let radius = bounds.height / 2
		(isHighlighted ? NSColor.tertiarySystemFill : NSColor.quaternarySystemFill).setFill()
		NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
		super.draw(dirtyRect)
	}

	override var focusRingMaskBounds: NSRect {
		bounds
	}

	override func drawFocusRingMask() {
		NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
	}

	override var intrinsicContentSize: NSSize {
		let title = attributedTitle.size()
		return NSSize(width: ceil(title.width) + 18, height: ceil(title.height) + 8)
	}

	@objc private func tagPressed() {
		onSelectScope(tagScope)
	}
}
