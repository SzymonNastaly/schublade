import AppKit
import ApplicationPresentation

/// The few kinds of text a page shows, so every page sets the same sizes and colours.
enum PageText {
	/// The page's title, such as a folder's name.
	static func title(_ text: String) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.font = NSFont.systemFont(ofSize: 22, weight: .bold)
		return label
	}

	/// A question or a heading inside a page, such as the confirmation's question.
	static func heading(_ text: String) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
		return label
	}

	/// A sentence that wraps to the column's width.
	static func body(_ text: String, color: NSColor = .labelColor) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
		label.textColor = color
		label.isSelectable = false
		return label
	}

	/// A quieter sentence, such as a path or a note under a group.
	static func secondary(_ text: String, selectable: Bool = false) -> NSTextField {
		let label = body(text, color: .secondaryLabelColor)
		label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		label.isSelectable = selectable
		return label
	}

	/// The colour that says what a collector's state means, from the website's sections.
	static func color(of tone: CollectorTone) -> NSColor {
		switch tone {
		case .processing:
			InterfacePalette.archive
		case .attention:
			InterfacePalette.attention
		case .failure:
			.systemRed
		case .success:
			InterfacePalette.collector
		case .neutral:
			.secondaryLabelColor
		}
	}
}
