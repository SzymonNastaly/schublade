import Foundation

/// Where a search's words occur in a text, so a row's excerpt and a reader mark the same words.
public enum SearchTextMarking {
	/// Each occurrence of a word of `searchText` in `text`, ignoring case and diacritics, in order
	/// and without overlaps.
	public static func matchedRanges(in text: String, searchText: String) -> [Range<String.Index>] {
		let terms = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
		var found: [Range<String.Index>] = []
		for term in terms {
			var start = text.startIndex
			while let range = text.range(
				of: term,
				options: [.caseInsensitive, .diacriticInsensitive],
				range: start ..< text.endIndex
			) {
				found.append(range)
				start = range.upperBound
			}
		}
		var merged: [Range<String.Index>] = []
		for range in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
			if let last = merged.last, range.lowerBound <= last.upperBound {
				merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
			} else {
				merged.append(range)
			}
		}
		return merged
	}
}
