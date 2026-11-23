import UIKit

/// The colours Schublade brings from its website into an otherwise native screen, the same as the
/// Mac's: blue for the archive, orange for what needs attention, and the link blue of titles. Each
/// has a dark variant, because the website has none. Controls take the AccentColor asset.
enum InterfacePalette {
	/// The documents section of the website, for the library's symbols and arriving documents.
	static let archive = dynamic(light: 0x4A97E3, dark: 0x5CA8F0)
	/// The failed documents section of the website, for what needs a person's attention.
	static let attention = dynamic(light: 0xE5850F, dark: 0xF5A03C)
	/// The website's link colour, for links to documents.
	static let link = dynamic(light: 0x0B57B0, dark: 0x7DB8FF)
	/// Behind the picture of a page, which is white in either appearance.
	nonisolated static let paper = UIColor.white
	/// The edge drawn into a page's picture, which shows on a light row and fades on a dark one.
	nonisolated static let pictureEdge = UIColor(white: 0.5, alpha: 0.35)
	/// Behind a page in the reader: the website's viewer grey, and the system's own in the dark.
	static let readerBackdrop = UIColor { traits in
		traits.userInterfaceStyle == .dark ? .secondarySystemBackground : color(0xDDE3EC)
	}

	private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
		UIColor { traits in
			color(traits.userInterfaceStyle == .dark ? dark : light)
		}
	}

	private static func color(_ value: UInt32) -> UIColor {
		UIColor(
			red: CGFloat((value >> 16) & 0xFF) / 255,
			green: CGFloat((value >> 8) & 0xFF) / 255,
			blue: CGFloat(value & 0xFF) / 255,
			alpha: 1
		)
	}
}
