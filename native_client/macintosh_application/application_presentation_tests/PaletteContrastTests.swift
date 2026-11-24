import ApplicationPresentation
import Foundation
import Testing

/// The palette's colours against the backgrounds behind them, by the contrast ratio of WCAG 2.1.
/// The backgrounds other than the selection fill were read from captures of macOS 26.6 on
/// 2026-11-23: the list and the welcome, the sidebar, and in the dark the lightest of the inspector
/// and the sidebar.
struct PaletteContrastTests {
	private static let lightBackgrounds: [UInt32] = [0xFFFFFF, 0xF7F7F7, PaletteColors.selectionFill.light]
	private static let darkBackgrounds: [UInt32] = [0x1E1E1E, 0x313639, PaletteColors.selectionFill.dark]
	/// The system's red, which the welcome's refusal symbol takes, in each appearance.
	private static let systemRed = PaletteColor(light: 0xFF3B30, dark: 0xFF453A)

	@Test func everySectionColourReadsAsTextOnEveryBackgroundBehindIt() {
		for color in [PaletteColors.archive, PaletteColors.attention, PaletteColors.collector] {
			for background in Self.lightBackgrounds {
				#expect(Self.contrast(color.light, background) >= 4.5)
			}
			for background in Self.darkBackgrounds {
				#expect(Self.contrast(color.dark, background) >= 4.5)
			}
		}
	}

	@Test func theSystemRedServesAsASymbolButNotAsText() {
		#expect(Self.contrast(Self.systemRed.light, 0xFFFFFF) >= 3)
		#expect(Self.contrast(Self.systemRed.light, 0xFFFFFF) < 4.5)
		#expect(Self.contrast(Self.systemRed.dark, 0x1E1E1E) >= 3)
	}

	private static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
		let lighter = max(luminance(first), luminance(second))
		let darker = min(luminance(first), luminance(second))
		return (lighter + 0.05) / (darker + 0.05)
	}

	private static func luminance(_ value: UInt32) -> Double {
		func linear(_ channel: UInt32) -> Double {
			let encoded = Double(channel & 0xFF) / 255
			return encoded <= 0.040_45 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
		}
		return 0.2126 * linear(value >> 16) + 0.7152 * linear(value >> 8) + 0.0722 * linear(value)
	}
}
