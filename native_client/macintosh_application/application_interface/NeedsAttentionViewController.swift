import AppKit
import ApplicationBindings
import ApplicationPresentation

/// Needs Attention: what only a person can settle on this Mac, such as a folder awaiting its
/// decision, a folder that cannot be read, a refused token, or refused files, each with the action
/// that settles it, and below them the documents whose ingestion failed.
final class NeedsAttentionViewController: NSViewController {
	private struct Shown: Equatable {
		let sentences: [AttentionSentence]
		let failedDocuments: UInt64
	}

	private let onAction: (AttentionAction) -> Void
	private let onShowFailedDocuments: () -> Void
	private let page = PageColumnView()
	private var shown: Shown?
	private var actions: [AttentionAction] = []

	init(onAction: @escaping (AttentionAction) -> Void, onShowFailedDocuments: @escaping () -> Void) {
		self.onAction = onAction
		self.onShowFailedDocuments = onShowFailedDocuments
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		view = page
	}

	func render(items: [AttentionItem], failedDocuments: UInt64, context: WordingContext) {
		let sentences = items.map { CollectorWording.attentionSentence($0, context: context) }
		let next = Shown(sentences: sentences, failedDocuments: failedDocuments)
		guard next != shown else {
			return
		}
		shown = next
		actions = []
		var views: [NSView] = [PageText.title("Needs Attention")]
		if sentences.isEmpty, failedDocuments == 0 {
			views.append(PageText.body("Nothing needs attention right now.", color: .secondaryLabelColor))
		}
		if !sentences.isEmpty {
			let section = PageSectionView(
				title: "On This Mac",
				symbolName: "exclamationmark.circle.fill",
				symbolColor: InterfacePalette.attention
			)
			for sentence in sentences {
				section.append(row(for: sentence))
			}
			views.append(section)
		}
		if failedDocuments > 0 {
			views.append(failedDocumentsSection(count: failedDocuments))
		}
		page.show(views)
	}

	private func row(for sentence: AttentionSentence) -> NSView {
		let mark =
			NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) ?? NSImage())
		mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
		mark.contentTintColor = PageText.color(of: sentence.tone)
		let text = PageText.body(sentence.text)
		text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		var views: [NSView] = [mark, text]
		if let action = sentence.action {
			let button = NSButton(title: Self.title(of: action), target: self, action: #selector(actionPressed(_:)))
			button.bezelStyle = .rounded
			button.controlSize = .small
			button.tag = actions.count
			actions.append(action)
			views.append(button)
		}
		let row = NSStackView(views: views)
		row.alignment = .firstBaseline
		row.spacing = 12
		return row
	}

	private func failedDocumentsSection(count: UInt64) -> NSView {
		let section = PageSectionView(
			title: "In the Archive",
			symbolName: "doc.badge.ellipsis",
			symbolColor: .systemRed
		)
		let sentence = count == 1
			? "The archive could not read 1 document."
			: "The archive could not read \(DocumentFormatting.groupedNumber(count)) documents."
		let show = NSButton(title: "Show Failed Documents", target: self, action: #selector(showFailedPressed))
		show.bezelStyle = .rounded
		show.controlSize = .small
		let row = NSStackView(views: [PageText.body(sentence), show])
		row.alignment = .firstBaseline
		row.spacing = 12
		section.append(row)
		section.append(PageText.secondary("Each one can be retried or deleted in the browser."))
		return section
	}

	private static func title(of action: AttentionAction) -> String {
		switch action {
		case .replaceToken:
			"Replace Token…"
		case .decideBacklog:
			"Review…"
		case .openFolder:
			"Show Folder"
		}
	}

	@objc private func actionPressed(_ sender: NSButton) {
		guard actions.indices.contains(sender.tag) else {
			return
		}
		onAction(actions[sender.tag])
	}

	@objc private func showFailedPressed() {
		onShowFailedDocuments()
	}
}
