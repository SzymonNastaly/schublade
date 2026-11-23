import AppKit
import PDFKit

/// Finds the words of a search in a PDF's text layer and in an extracted text, so the reader can
/// mark them and step through them.
enum SearchWordHighlighting {
	/// The most matches marked, so a common word does not walk a long document on the main actor.
	private static let largestMatchCount = 120
	private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

	/// The selections to mark, in the order of the document, each in the find colour.
	static func selections(in document: PDFDocument, terms: [String]) -> [PDFSelection] {
		var matches: [PDFSelection] = []
		for term in searchableTerms(terms) {
			matches.append(contentsOf: document.findString(term, withOptions: options))
			if matches.count >= largestMatchCount {
				break
			}
		}
		for match in matches {
			match.color = .findHighlightColor
		}
		return matches.sorted { first, second in
			let firstPage = first.pages.first.map { document.index(for: $0) } ?? 0
			let secondPage = second.pages.first.map { document.index(for: $0) } ?? 0
			guard firstPage == secondPage, let page = first.pages.first else {
				return firstPage < secondPage
			}
			// A page's coordinates rise upwards, so the higher bound comes first.
			return first.bounds(for: page).maxY > second.bounds(for: page).maxY
		}
	}

	/// The ranges of every term in a text, in the order of the text.
	static func ranges(in text: String, terms: [String]) -> [NSRange] {
		var matches: [NSRange] = []
		for term in searchableTerms(terms) {
			var searched = text.startIndex ..< text.endIndex
			while matches.count < largestMatchCount {
				guard let found = text.range(of: term, options: options, range: searched) else {
					break
				}
				matches.append(NSRange(found, in: text))
				searched = found.upperBound ..< text.endIndex
			}
		}
		return matches.sorted { $0.location < $1.location }
	}

	private static func searchableTerms(_ terms: [String]) -> [String] {
		terms.filter { $0.count >= 2 }
	}
}
