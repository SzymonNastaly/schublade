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
		contentTintColor = .controlAccentColor
		layer?.cornerRadius = 10
		layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
		layer?.borderWidth = 0.5
		layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor

		target = self
		action = #selector(tagPressed)
		setAccessibilityIdentifier("inspector.tag.\(tagScope.name)")
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override var intrinsicContentSize: NSSize {
		let base = super.intrinsicContentSize
		return NSSize(width: base.width + 16, height: max(base.height + 4, 22))
	}

	@objc private func tagPressed() {
		onSelectScope(tagScope)
	}
}
