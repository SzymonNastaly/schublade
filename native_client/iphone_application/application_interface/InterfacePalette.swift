import UIKit

/// The colours Schublade brings from its website into an otherwise native screen, the same as the
/// Mac's: blue for the archive, orange for what needs attention, and the link blue of titles. Each
/// has a dark variant, because the website has none. Controls and text in the archive's blue take
/// the AccentColor asset.
enum InterfacePalette {
	/// The documents section of the website, for graphics only, such as the ring of an upload: as
	/// text on white it measures 3.08:1, below the 4.5:1 that text needs.
	static let archive = dynamic(light: 0x4A97E3, dark: 0x5CA8F0)
	/// The orange of the website's failed documents, darkened in the light appearance to 5.09:1 on
	/// white, for the text and the symbols of what needs a person's attention.
	static let attentionText = dynamic(light: 0xA85A00, dark: 0xF5A03C)
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
