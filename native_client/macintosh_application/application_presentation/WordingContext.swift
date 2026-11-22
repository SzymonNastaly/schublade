import Foundation

/// Clocks, calendar, locale, and localized folder names injected into presentation wording so
/// tests and offscreen renders produce deterministic text.
public struct WordingContext: Sendable {
	public let now: Date
	public let calendar: Calendar
	public let locale: Locale
	public let folderName: @Sendable (String) -> String

	public init(
		now: Date,
		calendar: Calendar,
		locale: Locale,
		folderName: @escaping @Sendable (String) -> String
	) {
		self.now = now
		self.calendar = calendar
		self.locale = locale
		self.folderName = folderName
	}

	public static func current(
		folderName: @escaping @Sendable (String) -> String = { path in
			FileManager().displayName(atPath: path)
		}
	) -> WordingContext {
		WordingContext(
			now: Date(),
			calendar: Calendar.current,
			locale: Locale(identifier: "en_GB"),
			folderName: folderName
		)
	}
}
