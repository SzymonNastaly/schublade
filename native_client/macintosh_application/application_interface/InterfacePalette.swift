import AppKit
import ApplicationPresentation
import LibraryPresentation

/// The colours Schublade brings from its website into an otherwise native window: blue for the
/// archive, orange for what needs attention, and green for the folders on this Mac, each with a
/// dark variant, because the website has none. Their values are `PaletteColors`, whose test holds
/// them to 4.5:1 as text.
enum InterfacePalette {
	static let archive = dynamic(PaletteColors.archive)
	static let attention = dynamic(PaletteColors.attention)
	static let collector = dynamic(PaletteColors.collector)
	/// The fill of a selected document row; its edge is `selectionEdge`.
	static let selectionFill = dynamic(PaletteColors.selectionFill)
	static let selectionEdge = dynamic(light: 0x0B5CBF, dark: 0x4A97E3)
	/// A selected row in a list that does not have the keyboard.
	static let inactiveSelectionFill = dynamic(light: 0xE4E9F0, dark: 0x34383E)
	static let inactiveSelectionEdge = dynamic(light: 0x9AA6B6, dark: 0x6B7380)
	/// Behind a page in the reader: the website's viewer grey, and the system's own in the dark.
	static let readerBackdrop = NSColor(name: "readerBackdrop") { appearance in
		isDark(appearance) ? .underPageBackgroundColor : color(0xDDE3EC)
	}

	/// The symbol of a status line in its tone.
	static func statusLineSymbol(_ tone: StatusLineTone) -> NSColor {
		switch tone {
		case .normal: .secondaryLabelColor
		case .active: archive
		case .attention: attention
		}
	}

	private static func dynamic(_ palette: PaletteColor) -> NSColor {
		dynamic(light: palette.light, dark: palette.dark)
	}

	private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
		NSColor(name: nil) { appearance in
			color(isDark(appearance) ? dark : light)
		}
	}

	private static func isDark(_ appearance: NSAppearance) -> Bool {
		appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
	}

	private static func color(_ value: UInt32) -> NSColor {
		NSColor(
			srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
			green: CGFloat((value >> 8) & 0xFF) / 255,
			blue: CGFloat(value & 0xFF) / 255,
			alpha: 1
		)
	}
}
