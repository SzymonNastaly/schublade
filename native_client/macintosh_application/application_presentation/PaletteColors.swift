/// A colour as its sRGB value in the light appearance and in the dark one.
public struct PaletteColor: Equatable, Sendable {
	public let light: UInt32
	public let dark: UInt32

	public init(light: UInt32, dark: UInt32) {
		self.light = light
		self.dark = dark
	}
}

/// The website's colours that the Mac draws as text and small symbols, and the selection fill
/// they stand on. `PaletteContrastTests` holds each to 4.5:1 on the backgrounds behind it.
public enum PaletteColors {
	/// The documents section of the website, for the library's symbols and arriving documents.
	public static let archive = PaletteColor(light: 0x0B57B0, dark: 0x7DB8FF)
	/// The failed documents section of the website, for Needs Attention.
	public static let attention = PaletteColor(light: 0x9A5200, dark: 0xF5A03C)
	/// The settings section of the website, for the folders the collector watches.
	public static let collector = PaletteColor(light: 0x3F7000, dark: 0x9DCB45)
	/// The fill of a selected document row.
	public static let selectionFill = PaletteColor(light: 0xD6E7FB, dark: 0x1F3A5C)
}
