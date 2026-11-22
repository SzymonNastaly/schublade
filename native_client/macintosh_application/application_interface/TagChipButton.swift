import AppKit
import ApplicationBindings

/// Clickable rounded pill button representing one document tag inside the inspector.
final class TagChipButton: NSButton {
	private let tagScope: NamedScope
	private let onSelectScope: (NamedScope) -> Void

	init(tagScope: NamedScope, onSelectScope: @escaping (NamedScope) -> Void) {
		self.tagScope = tagScope
		self.onSelectScope = onSelectScope
		super.init(frame: .zero)

		title = tagScope.name
		isBordered = false
		wantsLayer = true
		font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
		contentTintColor = InterfacePalette.link
		layer?.cornerRadius = 10
		layer?.borderWidth = 0.5

		target = self
		action = #selector(tagPressed)
		setAccessibilityIdentifier("inspector.tag.\(tagScope.name)")
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	/// A layer keeps the colour it was given, so the chip's fill follows the appearance here.
	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		effectiveAppearance.performAsCurrentDrawingAppearance {
			layer?.backgroundColor = InterfacePalette.chipFill.cgColor
			layer?.borderColor = InterfacePalette.chipBorder.cgColor
		}
	}

	override var intrinsicContentSize: NSSize {
		let base = super.intrinsicContentSize
		return NSSize(width: base.width + 16, height: max(base.height + 4, 22))
	}

	@objc private func tagPressed() {
		onSelectScope(tagScope)
	}
}
