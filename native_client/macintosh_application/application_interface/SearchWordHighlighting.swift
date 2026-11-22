import PDFKit

/// Finds the words of a search in a PDF's text layer, so the reader can mark them.
enum SearchWordHighlighting {
	/// The most matches marked, so a common word does not walk a long document on the main actor.
	private static let largestMatchCount = 120

	/// The selections to mark, or nil when no term of at least two characters is found.
	static func selections(in document: PDFDocument, terms: [String]) -> [PDFSelection]? {
		var matches: [PDFSelection] = []
		for term in terms where term.count >= 2 {
			let found = document.findString(term, withOptions: [.caseInsensitive, .diacriticInsensitive])
			matches.append(contentsOf: found)
			if matches.count >= largestMatchCount {
				break
			}
		}
		return matches.isEmpty ? nil : matches
	}
}
