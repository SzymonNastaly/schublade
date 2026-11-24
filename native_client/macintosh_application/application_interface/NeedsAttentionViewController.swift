import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// Needs Attention: what only a person can settle, as rows in two groups like a pane of System
/// Settings. On this Mac a folder awaiting its decision, a folder that cannot be read, and refused
/// files; in the archive a refused token and the documents whose ingestion failed. Each row has at
/// most one button, the one that settles it. The window's title names the page, so it has no heading.
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

	func render(items: [AttentionItem], failedDocuments: UInt64, context: ApplicationWordingContext) {
		let sentences = items.map { CollectorWording.attentionSentence($0, context: context) }
		let next = Shown(sentences: sentences, failedDocuments: failedDocuments)
		guard next != shown else {
			return
		}
		shown = next
		actions = []
		var views: [NSView] = []
		let onThisMac = sentences.filter { $0.group == .thisMac }
		if !onThisMac.isEmpty {
			let group = PageRowGroupView(heading: "On This Mac")
			for sentence in onThisMac {
				group.appendRow(row(
					sentence.text,
					symbolName: sentence.symbolName,
					button: button(for: sentence.action)
				))
			}
			views.append(group)
		}
		let inTheArchive = sentences.filter { $0.group == .archive }
		if !inTheArchive.isEmpty || failedDocuments > 0 {
			let group = PageRowGroupView(heading: "In the Archive")
			for sentence in inTheArchive {
				group.appendRow(row(
					sentence.text,
					symbolName: sentence.symbolName,
					button: button(for: sentence.action)
				))
			}
			if failedDocuments > 0 {
				let show = NSButton(title: "Show Failed Documents", target: self, action: #selector(showFailedPressed))
				show.bezelStyle = .push
				group.appendRow(row(Self.failedSentence(failedDocuments), symbolName: "doc.text", button: show))
				group.appendNote("Each one can be retried or deleted in the browser.")
			}
			views.append(group)
		}
		if views.isEmpty {
			views.append(PageText.body("Nothing needs attention right now.", color: .secondaryLabelColor))
		}
		page.show(views)
	}

	/// A symbol in the one colour of this page, the sentence, and at most one button.
	private func row(_ text: String, symbolName: String, button: NSButton?) -> NSView {
		let symbol =
			NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage())
		symbol.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
		symbol.contentTintColor = InterfacePalette.attention
		symbol.widthAnchor.constraint(equalToConstant: 20).isActive = true
		let sentence = PageText.body(text)
		sentence.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		sentence.setContentHuggingPriority(.defaultLow, for: .horizontal)
		let row = NSStackView(views: [symbol, sentence] + (button.map { [$0] } ?? []))
		row.distribution = .fill
		row.alignment = .centerY
		row.spacing = 10
		return row
	}

	private func button(for action: AttentionAction?) -> NSButton? {
		guard let action else {
			return nil
		}
		let button = NSButton(title: Self.title(of: action), target: self, action: #selector(actionPressed(_:)))
		button.bezelStyle = .push
		button.tag = actions.count
		button.setContentHuggingPriority(.required, for: .horizontal)
		button.setContentCompressionResistancePriority(.required, for: .horizontal)
		actions.append(action)
		return button
	}

	private static func failedSentence(_ count: UInt64) -> String {
		count == 1
			? "The archive could not read 1 document."
			: "The archive could not read \(DocumentFormatting.groupedNumber(count)) documents."
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
