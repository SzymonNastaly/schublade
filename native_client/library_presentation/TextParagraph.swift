import Foundation

/// One paragraph of a document's extracted Markdown as a reader draws it.
public enum TextParagraph: Equatable, Sendable {
	/// "## Page 2" or "### Page 2", which the archive writes before each page's text.
	case pageMark(String)
	case heading(String)
	/// Consecutive rows of a table, without the rows of dashes that separate its head.
	case table([String])
	/// Consecutive lines up to a blank one, which stay one paragraph broken into lines.
	case prose([String])

	/// Breaks a line inside a paragraph, so the paragraph's spacing falls only between paragraphs.
	public static let lineSeparator = "\u{2028}"

	public static func paragraphs(of markdown: String) -> [TextParagraph] {
		var paragraphs: [TextParagraph] = []
		for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty {
				paragraphs.append(.prose([]))
				continue
			}
			if let heading = headingText(trimmed) {
				let isPageMark = heading.wholeMatch(of: /Page \d+/) != nil && trimmed.hasPrefix("##")
					&& !trimmed.hasPrefix("####")
				paragraphs.append(isPageMark ? .pageMark(heading) : .heading(heading))
			} else if trimmed.hasPrefix("|") {
				guard trimmed.contains(where: { !"|-: ".contains($0) }) else {
					continue
				}
				if case let .table(rows)? = paragraphs.last {
					paragraphs[paragraphs.count - 1] = .table(rows + [trimmed])
				} else {
					paragraphs.append(.table([trimmed]))
				}
			} else if case let .prose(lines)? = paragraphs.last, !lines.isEmpty {
				paragraphs[paragraphs.count - 1] = .prose(lines + [String(line)])
			} else {
				paragraphs.append(.prose([String(line)]))
			}
		}
		return paragraphs.filter { $0 != .prose([]) }
	}

	private static func headingText(_ line: String) -> String? {
		let words = line.drop { $0 == "#" }
		guard words.count < line.count, words.first == " " else {
			return nil
		}
		return words.trimmingCharacters(in: .whitespaces)
	}
}
