import LibraryPresentation
import Testing

/// The words of a search that an excerpt or a text marks.
struct SearchTextMarkingTests {
	/// Every occurrence of each word, whatever the case and the diacritics, and overlapping matches as one.
	@Test func aTextMarksEachOccurrenceOfTheSearchedWords() {
		let excerpt = "Prämie der Haftpflicht: die PRAMIE für Haftpflichtversicherung"

		let marked = SearchTextMarking.matchedRanges(in: excerpt, searchText: "pramie  haftpflicht pflicht")
			.map { String(excerpt[$0]) }

		#expect(marked == ["Prämie", "Haftpflicht", "PRAMIE", "Haftpflicht"])
	}
}
