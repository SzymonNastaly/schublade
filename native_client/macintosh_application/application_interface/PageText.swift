import AppKit
import ApplicationPresentation

/// The few kinds of text a page shows, so every page sets the same styles and colours.
enum PageText {
	/// The page's title, such as a folder's name.
	static func title(_ text: String) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.font = font(.title1, weight: .bold)
		return label
	}

	/// A question or a heading inside a page, such as the confirmation's question.
	static func heading(_ text: String) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.font = font(.title2, weight: .bold)
		return label
	}

	/// A sentence that wraps to the column's width.
	static func body(_ text: String, color: NSColor = .labelColor) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.font = NSFont.preferredFont(forTextStyle: .body)
		label.textColor = color
		label.isSelectable = false
		return label
	}

	/// A quieter sentence, such as a note under a group.
	static func secondary(_ text: String) -> NSTextField {
		let label = body(text, color: .secondaryLabelColor)
		label.font = NSFont.preferredFont(forTextStyle: .subheadline)
		return label
	}

	/// One line in the secondary colour with digits of one width, such as a count or a time in a column.
	static func figure(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
		let label = NSTextField(labelWithString: text)
		label.font = NSFont.monospacedDigitSystemFont(
			ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
			weight: .regular
		)
		label.textColor = color
		label.setContentHuggingPriority(.required, for: .horizontal)
		label.setContentCompressionResistancePriority(.required, for: .horizontal)
		return label
	}

	/// The colour that says what a collector's state means, from the website's sections.
	static func color(of tone: CollectorTone) -> NSColor {
		switch tone {
		case .attention:
			InterfacePalette.attention
		case .success:
			InterfacePalette.collector
		case .neutral:
			.secondaryLabelColor
		}
	}

	/// A spinner or a symbol in the tone's colour, the mark before a state or an outcome.
	static func mark(_ mark: CollectorStateMark, tone: CollectorTone, description: String) -> NSView {
		switch mark {
		case .progress:
			let spinner = NSProgressIndicator()
			spinner.style = .spinning
			spinner.controlSize = .small
			spinner.setAccessibilityLabel(description)
			spinner.startAnimation(nil)
			return spinner
		case let .symbol(name):
			let symbol = NSImageView(
				image: NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
			)
			symbol.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
			symbol.contentTintColor = color(of: tone)
			symbol.setContentHuggingPriority(.required, for: .horizontal)
			return symbol
		}
	}

	private static func font(_ style: NSFont.TextStyle, weight: NSFont.Weight) -> NSFont {
		NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
	}
}
