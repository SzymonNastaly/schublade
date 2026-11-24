import ApplicationBindings

/// Where a document's row shows, which decides its date and whether it has a third line.
public enum DocumentRowPlacement: Equatable, Sendable {
	/// A listing a person browses, under a month's heading when `underMonth`, which holds the year.
	case browsing(underMonth: Bool)
	/// The results of a search for `text`, whose third line is the passage that matched.
	case searching(text: String)
}

public extension DocumentRowPresentation {
	/// The row as a list places it. While a person browses, an archived document's summary repeats
	/// its title, so the row has no third line, and under a month's heading the date leaves the year
	/// to the heading. A stage or a failure always shows, and a search shows its passage.
	static func from(
		_ row: DocumentRow,
		placement: DocumentRowPlacement,
		context: WordingContext
	) -> DocumentRowPresentation {
		var shown = from(row, context: context)
		guard case let .browsing(underMonth) = placement else {
			return shown
		}
		if underMonth {
			shown.dateText = row.documentDate.map { DocumentFormatting.dayAndMonth($0, context: context) }
		}
		if case .archived = row.condition {
			shown.thirdLineText = ""
		}
		return shown
	}

	/// Whether the row has a third line, which then takes the title's second line.
	var showsThirdLine: Bool {
		!thirdLineText.isEmpty
	}
}
