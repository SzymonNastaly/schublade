import LibraryPresentation
import Testing

/// How a reader sets a table of the extracted text in a monospaced font.
struct TableColumnLayoutTests {
	/// The pipes go, each column takes the width of its widest cell, and a column of figures is set
	/// flush right under its head, while a column that also holds words stays flush left.
	@Test func aTableBecomesAlignedColumnsWithoutItsPipes() {
		let rows = [
			"| Zeitraum | Verbrauch | Betrag |",
			"| 01.09.2025 | 1.904 kWh | 606,23 EUR |",
			"|Grundpreis| | -139,53 EUR|",
		]
		#expect(TableColumnLayout.alignedRows(rows) == [
			"Zeitraum     Verbrauch        Betrag",
			"01.09.2025   1.904 kWh    606,23 EUR",
			"Grundpreis               -139,53 EUR",
		])
	}
}
