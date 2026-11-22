import AppKit

/// The colours Schublade brings from its website into an otherwise native window: blue for the
/// archive, orange for what needs attention, green for the folders on this Mac, and the link blue
/// of titles. Each has a dark variant, because the website has none.
enum InterfacePalette {
	/// The documents section of the website, for the library's symbols and arriving documents.
	static let archive = dynamic(light: 0x4A97E3, dark: 0x5CA8F0)
	/// The failed documents section of the website, for Needs Attention.
	static let attention = dynamic(light: 0xE5850F, dark: 0xF5A03C)
	/// The settings section of the website, for the folders the collector watches.
	static let collector = dynamic(light: 0x7FAE24, dark: 0x9DCB45)
	/// The website's link colour, for document titles and links to their documents.
	static let link = dynamic(light: 0x0B57B0, dark: 0x7DB8FF)
	/// The fill of a selected document row; its edge is `selectionEdge`.
	static let selectionFill = dynamic(light: 0xD6E7FB, dark: 0x1F3A5C)
	static let selectionEdge = dynamic(light: 0x0B5CBF, dark: 0x4A97E3)
	/// A selected row in a list that does not have the keyboard.
	static let inactiveSelectionFill = dynamic(light: 0xE4E9F0, dark: 0x34383E)
	static let inactiveSelectionEdge = dynamic(light: 0x9AA6B6, dark: 0x6B7380)
	static let chipFill = dynamic(light: 0xEAF2FC, dark: 0x1D324D)
	static let chipBorder = dynamic(light: 0xB7CBE6, dark: 0x35577F)
	/// Behind a page in the reader: the website's viewer grey, and the system's own in the dark.
	static let readerBackdrop = NSColor(name: "readerBackdrop") { appearance in
		isDark(appearance) ? .underPageBackgroundColor : color(0xDDE3EC)
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
