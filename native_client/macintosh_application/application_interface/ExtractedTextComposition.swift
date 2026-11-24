import AppKit
import LibraryPresentation

/// The extracted Markdown as a page to read: body text, page marks, headings without their marks,
/// and tables as aligned columns in a monospaced font, with the width of the widest row, which the
/// column makes room for so a row does not wrap.
struct ExtractedTextComposition {
	let text: NSAttributedString
	let widestTableRow: CGFloat

	init(markdown: String) {
		let text = NSMutableAttributedString()
		var widestTableRow: CGFloat = 0
		for paragraph in TextParagraph.paragraphs(of: markdown) {
			if text.length > 0 {
				text.append(NSAttributedString(string: "\n", attributes: TextStyle.body.attributes))
			}
			switch paragraph {
			case let .pageMark(mark):
				text.append(NSAttributedString(string: mark, attributes: TextStyle.pageMark.attributes))
			case let .heading(heading):
				text.append(NSAttributedString(string: heading, attributes: TextStyle.heading.attributes))
			case let .table(rows):
				for (index, row) in TableColumnLayout.alignedRows(rows).enumerated() {
					let style = index == 0 ? TextStyle.tableHead : TextStyle.table
					let line = NSAttributedString(string: row, attributes: style.attributes)
					widestTableRow = max(widestTableRow, ceil(line.size().width))
					if index > 0 {
						text.append(NSAttributedString(
							string: TextParagraph.lineSeparator,
							attributes: style.attributes
						))
					}
					text.append(line)
				}
			case let .prose(lines):
				let separator = NSAttributedString(
					string: TextParagraph.lineSeparator,
					attributes: TextStyle.body.attributes
				)
				for (index, line) in lines.enumerated() {
					if index > 0 {
						text.append(separator)
					}
					text.append(Self.inlineText(line))
				}
			}
		}
		self.text = text
		self.widestTableRow = widestTableRow
	}

	/// The links a click follows. The text was extracted from a document anyone could have sent, so
	/// a link that opens another application's scheme stays plain text.
	private static let linkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

	/// A line with its emphasis, code, and links read as Markdown, or as it stands when it is none.
	private static func inlineText(_ line: String) -> NSAttributedString {
		let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
		guard let parsed = try? AttributedString(markdown: line, options: options) else {
			return NSAttributedString(string: line, attributes: TextStyle.body.attributes)
		}
		let body = TextStyle.bodyFont
		let text = NSMutableAttributedString()
		for run in parsed.runs {
			var attributes = TextStyle.body.attributes
			let intent = run.inlinePresentationIntent ?? []
			if intent.contains(.code) {
				attributes[.font] = NSFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
			} else {
				var traits: NSFontDescriptor.SymbolicTraits = []
				if intent.contains(.stronglyEmphasized) {
					traits.insert(.bold)
				}
				if intent.contains(.emphasized) {
					traits.insert(.italic)
				}
				if !traits.isEmpty {
					attributes[.font] = NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(traits), size: 0)
						?? body
				}
			}
			if let link = run.link, link.scheme.map({ linkSchemes.contains($0.lowercased()) }) ?? false {
				attributes[.link] = link
			}
			text.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
		}
		return text
	}
}

private enum TextStyle {
	case body
	case pageMark
	case heading
	case tableHead
	case table

	static var bodyFont: NSFont {
		NSFont.preferredFont(forTextStyle: .body)
	}

	var attributes: [NSAttributedString.Key: Any] {
		let paragraph = NSMutableParagraphStyle()
		paragraph.lineHeightMultiple = 1.2
		paragraph.paragraphSpacing = 8
		switch self {
		case .body:
			return [.font: Self.bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
		case .pageMark:
			paragraph.paragraphSpacingBefore = 24
			let subheadline = NSFont.preferredFont(forTextStyle: .subheadline)
			return [
				.font: NSFont.systemFont(ofSize: subheadline.pointSize, weight: .semibold),
				.foregroundColor: NSColor.secondaryLabelColor,
				.paragraphStyle: paragraph,
			]
		case .heading:
			return [
				.font: NSFont.preferredFont(forTextStyle: .headline),
				.foregroundColor: NSColor.labelColor,
				.paragraphStyle: paragraph,
			]
		case .tableHead, .table:
			paragraph.lineHeightMultiple = 1.1
			return [
				.font: NSFont.monospacedSystemFont(ofSize: 11, weight: self == .tableHead ? .semibold : .regular),
				.foregroundColor: NSColor.labelColor,
				.paragraphStyle: paragraph,
			]
		}
	}
}
