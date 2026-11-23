import Foundation

/// Clocks, calendar, and locale injected into presentation wording so tests and offscreen renders
/// produce deterministic text.
public struct WordingContext: Sendable {
	public let now: Date
	public let calendar: Calendar
	public let locale: Locale

	public init(now: Date, calendar: Calendar, locale: Locale) {
		self.now = now
		self.calendar = calendar
		self.locale = locale
	}

	public static func current() -> WordingContext {
		WordingContext(now: Date(), calendar: Calendar.current, locale: Locale(identifier: "en_GB"))
	}
}
