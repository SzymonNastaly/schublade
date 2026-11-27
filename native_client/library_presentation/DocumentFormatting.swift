import ApplicationBindings
import Foundation

/// Locale-fixed and calendar-aware formatting for numbers, dates, amounts, periods, and IBANs.
public enum DocumentFormatting {
	private static let englishUnitedStates = Locale(identifier: "en_US_POSIX")
	private static let englishGreatBritain = Locale(identifier: "en_GB")

	private static let periodUnits: [Character: String] = [
		"Y": "year",
		"M": "month",
		"W": "week",
		"D": "day",
	]

	public static var universalGregorianCalendar: Calendar {
		var calendar = Calendar(identifier: .gregorian)
		if let universalTimeZone = TimeZone(secondsFromGMT: 0) {
			calendar.timeZone = universalTimeZone
		}
		return calendar
	}

	public static func groupedNumber(_ value: UInt64) -> String {
		value.formatted(.number.locale(Locale(identifier: "en_US")))
	}

	public static func countText(_ value: UInt64, singular: String) -> String {
		let noun = value == 1 ? singular : "\(singular)s"
		return "\(groupedNumber(value)) \(noun)"
	}

	public static func byteSize(_ bytes: UInt64) -> String {
		byteSize(bytes, fractionLength: 1)
	}

	/// `fractionLength` 0 suits sizes chosen as whole units, such as a storage limit.
	public static func byteSize(_ bytes: UInt64, fractionLength: Int) -> String {
		let units = ["bytes", "KB", "MB", "GB"]
		var scaled = Double(bytes)
		var unitIndex = 0
		while scaled >= 1000, unitIndex < units.count - 1 {
			scaled /= 1000
			unitIndex += 1
		}
		if unitIndex == 0 {
			return "\(groupedNumber(bytes)) bytes"
		}
		let formatted = scaled.formatted(
			.number
				.precision(.fractionLength(fractionLength))
				.locale(englishGreatBritain)
		)
		return "\(formatted) \(units[unitIndex])"
	}

	public static func calendarDate(_ date: CalendarDate, context _: WordingContext) -> String {
		guard let timestamp = timestamp(of: date) else {
			return isoDate(date)
		}
		let calendar = universalGregorianCalendar
		return timestamp.formatted(
			Date.FormatStyle(
				date: .abbreviated,
				time: .omitted,
				locale: englishGreatBritain,
				calendar: calendar,
				timeZone: calendar.timeZone
			)
		)
	}

	/// "31 Oct", for a row under a month's heading, which holds the year.
	public static func dayAndMonth(_ date: CalendarDate, context _: WordingContext) -> String {
		guard let timestamp = timestamp(of: date) else {
			return isoDate(date)
		}
		let calendar = universalGregorianCalendar
		return timestamp.formatted(
			Date.FormatStyle(locale: englishGreatBritain, calendar: calendar, timeZone: calendar.timeZone)
				.day()
				.month(.abbreviated)
		)
	}

	/// The start of the day in universal time, nil for a day the calendar lacks.
	private static func timestamp(of date: CalendarDate) -> Date? {
		let calendar = universalGregorianCalendar
		return calendar.date(from: DateComponents(
			calendar: calendar,
			timeZone: calendar.timeZone,
			year: Int(date.year),
			month: Int(date.month),
			day: Int(date.day)
		))
	}

	public static func isoDate(_ date: CalendarDate) -> String {
		String(format: "%04u-%02u-%02u", UInt32(date.year), UInt32(date.month), UInt32(date.day))
	}

	public static func dayOfTimestamp(_ timestamp: Date, context: WordingContext) -> String {
		timestamp.formatted(
			Date.FormatStyle(
				date: .abbreviated,
				time: .omitted,
				locale: englishGreatBritain,
				calendar: context.calendar,
				timeZone: context.calendar.timeZone
			)
		)
	}

	public static func monthHeading(year: UInt16, month: UInt8, context _: WordingContext) -> String {
		let calendar = universalGregorianCalendar
		let components = DateComponents(
			calendar: calendar,
			timeZone: calendar.timeZone,
			year: Int(year),
			month: Int(month),
			day: 1
		)
		guard let timestamp = calendar.date(from: components) else {
			return String(format: "%04u-%02u", UInt32(year), UInt32(month))
		}
		return timestamp.formatted(
			Date.FormatStyle(
				locale: englishGreatBritain,
				calendar: calendar,
				timeZone: calendar.timeZone
			)
			.year()
			.month(.wide)
		)
	}

	public static func clockTime(_ timestamp: Date, context: WordingContext) -> String {
		timestamp.formatted(
			Date.FormatStyle(
				date: .omitted,
				time: .shortened,
				locale: context.locale,
				calendar: context.calendar,
				timeZone: context.calendar.timeZone
			)
		)
	}

	public static func amount(_ amount: Amount) -> String {
		decimalAmount(amount.decimalText, currency: amount.currency)
	}

	/// The amount among a document's extracted fields with its currency, nil when it names no amount
	/// as a number.
	public static func amountText(in fields: [DetailField]) -> String? {
		fields.first { $0.key == "amount" }.flatMap { field in
			if case let .number(decimalText) = field.value {
				decimalAmount(decimalText, currency: currency(in: fields))
			} else {
				nil
			}
		}
	}

	static func currency(in fields: [DetailField]) -> String? {
		fields.first { $0.key == "currency" }.flatMap { field in
			if case let .text(text) = field.value, !text.isEmpty {
				text
			} else {
				nil
			}
		}
	}

	public static func decimalAmount(_ decimalText: String, currency: String? = nil) -> String {
		let numberText = if let decimal = Decimal(string: decimalText, locale: englishUnitedStates) {
			decimal.formatted(
				.number
					.precision(.fractionLength(2))
					.locale(englishGreatBritain)
			)
		} else {
			decimalText
		}
		guard let currency, !currency.isEmpty else {
			return numberText
		}
		return "\(numberText) \(currency)"
	}

	public static func formattedIban(_ raw: String) -> String {
		let compact = plainIban(raw)
		guard !compact.isEmpty else {
			return raw
		}
		var groups: [String] = []
		var index = compact.startIndex
		while index < compact.endIndex {
			let nextIndex = compact.index(index, offsetBy: 4, limitedBy: compact.endIndex) ?? compact.endIndex
			groups.append(String(compact[index ..< nextIndex]))
			index = nextIndex
		}
		return groups.joined(separator: " ")
	}

	public static func plainIban(_ raw: String) -> String {
		String(raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }).uppercased()
	}

	public static func formattedPeriod(_ period: String) -> String {
		guard period.count >= 3, period.first == "P", let unitCharacter = period.last,
		      let unitName = periodUnits[unitCharacter]
		else {
			return period
		}
		let countSlice = period.dropFirst().dropLast()
		guard let count = UInt64(countSlice), !countSlice.isEmpty else {
			return period
		}
		return countText(count, singular: unitName)
	}

	public static func headingText(_ heading: ListingHeading, context: WordingContext) -> String {
		switch heading {
		case .arriving:
			"Arriving"
		case let .period(year, month):
			monthHeading(year: year, month: month, context: context)
		case .detailsMatched:
			"Matches in Details"
		case .textMatched:
			"Matches in Text"
		}
	}
}
