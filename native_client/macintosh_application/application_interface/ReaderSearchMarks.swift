import AppKit
import ApplicationBindings
import PDFKit

/// The words of a search that the reader marks on the page and in the text, and the one a person
/// stepped to with Find Next or Find Previous. Each surface is marked once for each document and
/// search, so a render that changes neither keeps the person's place.
final class ReaderSearchMarks {
	enum Surface {
		case page
		case text
	}

	struct Placement: Equatable {
		let document: DocumentIdentifier
		let terms: [String]
	}

	private let pdfView: PDFView
	private let textView: ExtractedTextView
	private let showsFindIndicator: Bool
	private var pageMatches: [PDFSelection] = []
	private var pagePlacement: Placement?
	private var textMatches: [NSRange] = []
	private var textPlacement: Placement?
	private var position = 0

	init(pdfView: PDFView, textView: ExtractedTextView, showsFindIndicator: Bool) {
		self.pdfView = pdfView
		self.textView = textView
		self.showsFindIndicator = showsFindIndicator
	}

	func reset() {
		pageMatches = []
		pagePlacement = nil
		textMatches = []
		textPlacement = nil
		textView.string = ""
		textView.widestTableRow = 0
	}

	func count(on surface: Surface) -> Int {
		surface == .page ? pageMatches.count : textMatches.count
	}

	/// Whether the page holds a search's words, from its marks once it is marked.
	func pageHoldsMatches(of placement: Placement, in document: PDFDocument) -> Bool {
		pagePlacement == placement
			? !pageMatches.isEmpty
			: !SearchWordHighlighting.selections(in: document, terms: placement.terms).isEmpty
	}

	/// Marks the search's words on the page and goes to the first.
	func mark(_ document: PDFDocument, as placement: Placement) {
		guard pagePlacement != placement else {
			return
		}
		pagePlacement = placement
		pageMatches = SearchWordHighlighting.selections(in: document, terms: placement.terms)
		pdfView.highlightedSelections = pageMatches.isEmpty ? nil : pageMatches
		position = 0
		guard !pageMatches.isEmpty else {
			return
		}
		// PDFView scales the page to its width at its next layout, which would move it again.
		Task { @MainActor [weak self] in
			guard let self, pagePlacement == placement else {
				return
			}
			pdfView.layoutDocumentView()
			reveal(on: .page, selecting: false)
		}
	}

	/// Shows the text as a page to read with the search's words on the find colour, and scrolls to
	/// the first.
	func mark(_ markdown: String, as placement: Placement) {
		guard textPlacement != placement else {
			return
		}
		textPlacement = placement
		let composition = ExtractedTextComposition(markdown: markdown)
		textMatches = SearchWordHighlighting.ranges(in: composition.text.string, terms: placement.terms)
		textView.widestTableRow = composition.widestTableRow
		textView.textStorage?.setAttributedString(Self.markedText(composition.text, matches: textMatches))
		position = 0
		if textMatches.isEmpty {
			textView.scrollToBeginningOfDocument(nil)
		} else {
			reveal(on: .text, selecting: false)
		}
	}

	/// Shows the next match, or the previous one for a negative step, and wraps at either end.
	func step(by step: Int, on surface: Surface) {
		let count = count(on: surface)
		guard count > 0 else {
			return
		}
		position = ((position + step) % count + count) % count
		reveal(on: surface, selecting: true)
	}

	private func reveal(on surface: Surface, selecting: Bool) {
		switch surface {
		case .page where pageMatches.indices.contains(position):
			let match = pageMatches[position]
			if selecting {
				pdfView.setCurrentSelection(match, animate: true)
			}
			guard let page = match.pages.first else {
				return
			}
			// `go(to:)` puts a selection at the view's top edge, under the toolbar, so the match goes
			// to a point above it by the toolbar's height and a little more, in the page's units.
			let margin = (pdfView.safeAreaInsets.top + 48) / max(pdfView.scaleFactor, 0.01)
			let bounds = match.bounds(for: page)
			pdfView.go(to: PDFDestination(
				page: page,
				at: NSPoint(x: page.bounds(for: pdfView.displayBox).minX, y: bounds.maxY + margin)
			))
		case .text where textMatches.indices.contains(position):
			let range = textMatches[position]
			textView.scrollRangeToVisible(range)
			if selecting {
				textView.setSelectedRange(range)
			}
			if showsFindIndicator, textView.window != nil {
				textView.showFindIndicator(for: range)
			}
		default:
			break
		}
	}

	/// The text with each match on the find colour, which is yellow in both appearances, so a
	/// match's letters stay dark on it.
	private static func markedText(_ text: NSAttributedString, matches: [NSRange]) -> NSAttributedString {
		let marked = NSMutableAttributedString(attributedString: text)
		for range in matches {
			marked.addAttributes(
				[.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black],
				range: range
			)
		}
		return marked
	}
}
