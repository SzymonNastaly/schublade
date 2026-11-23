import ApplicationBindings
import LibraryPresentation
import UIKit

/// The text the archive read from a document, a page of its own one step past the original,
/// because a person reads the original and the details far more often.
final class DocumentTextViewController: UIViewController {
	enum TextState: Equatable {
		case loading
		case text(String)
		case unavailable(RepresentationPlaceholder)
	}

	private let gateway: ApplicationGateway
	private let document: DocumentIdentifier
	private(set) var state = TextState.loading
	private var newestRequest: UInt64 = 0
	/// The words a search found in the text, which the find navigator shows once the text is read
	/// and the page is on the screen.
	private var pendingSearchText: String?
	let textView = UITextView()

	init(gateway: ApplicationGateway, document: DocumentIdentifier, searchText: String?) {
		self.gateway = gateway
		self.document = document
		pendingSearchText = searchText
		super.init(nibName: nil, bundle: nil)
		title = "Text"
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		navigationItem.largeTitleDisplayMode = .never
		view.backgroundColor = .systemBackground
		textView.isEditable = false
		textView.isFindInteractionEnabled = true
		textView.textContainer.lineFragmentPadding = 0
		textView.backgroundColor = .systemBackground
		textView.dataDetectorTypes = [.link, .phoneNumber]
		textView.accessibilityIdentifier = "document.text"
		textView.frame = view.bounds
		textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		view.addSubview(textView)
		// The fonts of an attributed text are fixed when it is built, so a new text size builds it again.
		registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
			if case let .text(markdown) = self.state {
				self.textView.attributedText = Self.readableText(markdown)
			}
		}
		load()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		navigationController?.setToolbarHidden(true, animated: animated)
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		presentPendingSearch()
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		let readable = view.readableContentGuide.layoutFrame
		let inset = UIEdgeInsets(
			top: 16,
			left: max(20, readable.minX),
			bottom: 24,
			right: max(20, view.bounds.width - readable.maxX)
		)
		if textView.textContainerInset != inset {
			textView.textContainerInset = inset
		}
	}

	func contentRevisionChanged() {
		if case .unavailable = state {
			load()
		}
	}

	private func load() {
		newestRequest &+= 1
		let request = newestRequest
		Task {
			let next: TextState
			do throws(RepresentationRefusal) {
				next = try await .text(gateway.extractedText(document))
			} catch {
				next = .unavailable(LibraryFailureWording.extractedTextRefusalPlaceholder(error))
			}
			guard request == newestRequest else {
				return
			}
			show(next)
		}
	}

	private func show(_ next: TextState) {
		state = next
		textView.isHidden = true
		switch next {
		case .loading:
			contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
		case let .text(markdown):
			contentUnavailableConfiguration = nil
			textView.attributedText = Self.readableText(markdown)
			textView.isHidden = false
			presentPendingSearch()
		case let .unavailable(placeholder):
			var configuration = UIContentUnavailableConfiguration.empty()
			configuration.image = UIImage(systemName: "text.page.slash")
			configuration.text = placeholder.title
			configuration.secondaryText = placeholder.detail
			if placeholder.canRetry {
				configuration.button = .plain()
				configuration.button.title = "Try Again"
				configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
			}
			contentUnavailableConfiguration = configuration
		}
	}

	private func presentPendingSearch() {
		guard let searchText = pendingSearchText, case .text = state, view.window != nil,
		      let find = textView.findInteraction
		else {
			return
		}
		pendingSearchText = nil
		find.searchText = searchText
		find.presentFindNavigator(showingReplace: false)
	}

	static func readableText(_ markdown: String) -> NSAttributedString {
		let text = NSMutableAttributedString()
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
				text.append(NSAttributedString(
					string: rows.joined(separator: TextParagraph.lineSeparator),
					attributes: TextStyle.table.attributes
				))
			case let .prose(lines):
				let separator = NSAttributedString(
					string: TextParagraph.lineSeparator,
					attributes: TextStyle.body.attributes
				)
				for (index, line) in lines.enumerated() {
					if index > 0 {
						text.append(separator)
					}
					text.append(inlineText(line))
				}
			}
		}
		return text
	}

	/// A line with its emphasis, code, and links read as Markdown, or as it stands when it is none.
	private static func inlineText(_ line: String) -> NSAttributedString {
		let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
		guard let parsed = try? AttributedString(markdown: line, options: options) else {
			return NSAttributedString(string: line, attributes: TextStyle.body.attributes)
		}
		let text = NSMutableAttributedString()
		for run in parsed.runs {
			var attributes = TextStyle.body.attributes
			let intent = run.inlinePresentationIntent ?? []
			if intent.contains(.code) {
				attributes[.font] = UIFont.monospacedSystemFont(ofSize: TextStyle.bodyFont.pointSize, weight: .regular)
			} else {
				var traits: UIFontDescriptor.SymbolicTraits = []
				if intent.contains(.stronglyEmphasized) {
					traits.insert(.traitBold)
				}
				if intent.contains(.emphasized) {
					traits.insert(.traitItalic)
				}
				if let descriptor = TextStyle.bodyFont.fontDescriptor.withSymbolicTraits(traits) {
					attributes[.font] = UIFont(descriptor: descriptor, size: 0)
				}
			}
			if let link = run.link {
				attributes[.link] = link
			}
			text.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
		}
		return text
	}
}

/// One paragraph of the extracted Markdown as the text page draws it.
enum TextParagraph: Equatable {
	/// "## Page 2" or "### Page 2", which the archive writes before each page's text.
	case pageMark(String)
	case heading(String)
	/// Consecutive rows of a table, without the rows of dashes that separate its head.
	case table([String])
	/// Consecutive lines up to a blank one, which stay one paragraph broken into lines.
	case prose([String])

	/// Breaks a line inside a paragraph, so the paragraph's spacing falls only between paragraphs.
	static let lineSeparator = "\u{2028}"

	static func paragraphs(of markdown: String) -> [TextParagraph] {
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

private enum TextStyle {
	case body
	case pageMark
	case heading
	case table

	static var bodyFont: UIFont {
		UIFont.preferredFont(forTextStyle: .body)
	}

	var attributes: [NSAttributedString.Key: Any] {
		let paragraph = NSMutableParagraphStyle()
		paragraph.lineHeightMultiple = 1.15
		paragraph.paragraphSpacing = 8
		switch self {
		case .body:
			return [.font: Self.bodyFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
		case .pageMark:
			paragraph.paragraphSpacingBefore = 24
			let footnote = UIFont.preferredFont(forTextStyle: .footnote)
			let semibold = footnote.fontDescriptor.addingAttributes([
				.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold],
			])
			return [
				.font: UIFont(descriptor: semibold, size: 0),
				.foregroundColor: UIColor.secondaryLabel,
				.paragraphStyle: paragraph,
			]
		case .heading:
			return [
				.font: UIFont.preferredFont(forTextStyle: .headline),
				.foregroundColor: UIColor.label,
				.paragraphStyle: paragraph,
			]
		case .table:
			let size = UIFont.preferredFont(forTextStyle: .footnote).pointSize
			return [
				.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular),
				.foregroundColor: UIColor.label,
				.paragraphStyle: paragraph,
			]
		}
	}
}
