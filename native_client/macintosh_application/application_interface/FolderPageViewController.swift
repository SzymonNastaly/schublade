import AppKit
import ApplicationBindings
import ApplicationPresentation

/// One folder on this Mac: its survey's progress, then the confirmation of what happens to the
/// files already there, then the collecting page with the latest uploads. The confirmation is a
/// page, not a sheet, so a person can leave it, read a document, and come back.
final class FolderPageViewController: NSViewController {
	private struct Shown: Equatable {
		let folder: FolderStatus
		let receipts: [Receipt]
		let failure: String?
		let commandPending: Bool
	}

	private let commands: any CollectorCommands
	private let renderMode: InterfaceRenderMode
	private let onSelectDocument: (DocumentIdentifier) -> Void
	private let page = PageColumnView()
	private var shown: Shown?
	private var folder: FolderStatus?
	private var receipts: [Receipt] = []
	private var context: WordingContext?
	private var failure: String?
	private var commandPending = false

	init(
		commands: any CollectorCommands,
		renderMode: InterfaceRenderMode,
		onSelectDocument: @escaping (DocumentIdentifier) -> Void
	) {
		self.commands = commands
		self.renderMode = renderMode
		self.onSelectDocument = onSelectDocument
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		view = page
	}

	func render(folder: FolderStatus?, receipts: [Receipt], context: WordingContext) {
		if folder?.folder.identifier != self.folder?.folder.identifier {
			failure = nil
			commandPending = false
		}
		self.folder = folder
		self.receipts = receipts
		self.context = context
		rebuild()
	}

	private func rebuild() {
		guard let folder, let context else {
			page.show([PageText.body("This folder is no longer collected.", color: .secondaryLabelColor)])
			shown = nil
			return
		}
		let next = Shown(folder: folder, receipts: receipts, failure: failure, commandPending: commandPending)
		guard next != shown else {
			return
		}
		shown = next
		let name = context.folderName(folder.folder.root)
		var views: [NSView] = [header(name: name, folder: folder), stateLine(CollectorWording.folderState(folder))]
		switch folder.admission {
		case .surveying:
			break
		case let .awaitingDecision(backlog):
			views += confirmation(BacklogConfirmationWording.make(folderName: name, backlog: backlog))
		case .collecting:
			if !receipts.isEmpty {
				views.append(recentUploads(context: context))
			}
		}
		if let failure {
			let label = PageText.body(failure, color: .systemRed)
			label.setAccessibilityIdentifier(InterfaceIdentifier.folderPageFailure)
			views.append(label)
		}
		views.append(PageText.secondary(Self.collectionNote))
		page.show(views)
	}

	private static let collectionNote = "Schublade reads the PDF, JPEG, PNG, and WebP files in this folder and its "
		+ "subfolders. It never changes, moves, or deletes your files, and removing the folder keeps what Schublade "
		+ "received."
}

private extension FolderPageViewController {
	func header(name: String, folder: FolderStatus) -> NSView {
		let symbol =
			NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage())
		symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
		symbol.contentTintColor = InterfacePalette.collector
		let title = PageText.title(name)
		title.setAccessibilityIdentifier(InterfaceIdentifier.folderPageTitle)
		let names = NSStackView(views: [title, PageText.secondary(folder.folder.root, selectable: true)])
		names.orientation = .vertical
		names.alignment = .leading
		names.spacing = 2
		var views: [NSView] = [symbol, names]
		switch folder.admission {
		case .awaitingDecision:
			// The confirmation offers its own removal beside its upload.
			break
		case .surveying, .collecting:
			let remove = NSButton(title: "Remove Folder…", target: self, action: #selector(removePressed))
			remove.bezelStyle = .rounded
			remove.isEnabled = !commandPending
			remove.setAccessibilityIdentifier(InterfaceIdentifier.folderPageRemoveButton)
			views.append(remove)
		}
		let row = NSStackView(views: views)
		row.distribution = .fill
		row.alignment = .centerY
		row.spacing = 12
		names.setContentHuggingPriority(.defaultLow, for: .horizontal)
		return row
	}

	func stateLine(_ state: FolderStatePresentation) -> NSView {
		let badge = NSTextField(labelWithString: state.label)
		badge.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		badge.textColor = PageText.color(of: state.tone)
		badge.setAccessibilityIdentifier(InterfaceIdentifier.folderPageState)
		var views: [NSView] = [badge]
		if state.tone == .processing {
			let spinner = NSProgressIndicator()
			spinner.style = .spinning
			spinner.controlSize = .small
			spinner.startAnimation(nil)
			views.insert(spinner, at: 0)
		}
		let line = NSStackView(views: views)
		line.spacing = 6
		guard let detail = state.detail else {
			return line
		}
		let block = NSStackView(views: [line, PageText.body(detail, color: .secondaryLabelColor)])
		block.orientation = .vertical
		block.alignment = .leading
		block.spacing = 4
		return block
	}

	func confirmation(_ wording: BacklogConfirmationWording) -> [NSView] {
		let existing = PageSectionView(title: wording.existingFilesHeading, symbolName: "doc.on.doc")
		for sentence in wording.existingFiles {
			existing.append(PageText.body(sentence))
		}
		if let summary = wording.skippedSummary {
			existing.append(PageText.body(summary))
			existing.append(skippedGrid(wording.skippedGroups))
		}
		if let note = wording.examinationNote {
			existing.append(PageText.secondary(note))
		}
		let future = PageSectionView(
			title: wording.futureFilesHeading,
			symbolName: "arrow.triangle.2.circlepath",
			symbolColor: InterfacePalette.archive
		)
		future.append(PageText.body(wording.futureFiles))

		let remove = NSButton(title: wording.removeLabel, target: self, action: #selector(removePressed))
		remove.bezelStyle = .rounded
		let upload = NSButton(title: wording.uploadLabel, target: self, action: #selector(uploadPressed))
		upload.bezelStyle = .rounded
		upload.keyEquivalent = "\r"
		upload.setAccessibilityIdentifier(InterfaceIdentifier.folderPageUploadButton)
		for button in [remove, upload] {
			button.isEnabled = !commandPending
		}
		let buttons = NSStackView(views: [NSView(), remove, upload])
		buttons.spacing = 8
		return [PageText.heading(wording.heading), existing, future, buttons]
	}

	func skippedGrid(_ groups: [SkippedGroup]) -> NSView {
		let grid = NSGridView(views: groups.map { group in
			let count = PageText.secondary(group.count)
			count.alignment = .right
			return [PageText.secondary(group.reason), count]
		})
		grid.columnSpacing = 24
		grid.rowSpacing = 3
		grid.column(at: 1).xPlacement = .trailing
		return grid
	}

	func recentUploads(context: WordingContext) -> NSView {
		let section = PageSectionView(
			title: "Recently Uploaded from This Mac",
			symbolName: "arrow.up.doc",
			symbolColor: InterfacePalette.collector
		)
		for receipt in receipts.prefix(8) {
			section.append(receiptRow(receipt, context: context))
		}
		return section
	}

	func receiptRow(_ receipt: Receipt, context: WordingContext) -> NSView {
		let name = NSButton(title: receipt.fileName, target: self, action: #selector(receiptPressed(_:)))
		name.isBordered = false
		name.contentTintColor = InterfacePalette.link
		name.lineBreakMode = .byTruncatingMiddle
		name.identifier = NSUserInterfaceItemIdentifier(receipt.documentIdentifier)
		name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		let outcome = CollectorWording.receiptOutcome(receipt.outcome)
		let label = NSTextField(labelWithString: outcome.label)
		label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
		label.textColor = PageText.color(of: outcome.tone)
		let time = PageText.secondary(CollectorWording.receiptTime(receipt.receivedAt, context: context))
		time.setContentHuggingPriority(.required, for: .horizontal)
		let row = NSStackView(views: [name, NSView(), label, time])
		row.spacing = 10
		return row
	}

	@objc func receiptPressed(_ sender: NSButton) {
		guard let identifier = sender.identifier?.rawValue else {
			return
		}
		onSelectDocument(DocumentIdentifier(value: identifier))
	}

	@objc func uploadPressed() {
		guard let folder, let context else {
			return
		}
		perform { commands throws(DecisionRefusal) in
			try await commands.decideBacklog(folder.folder.identifier)
		} describing: { CollectorRefusalWording.decisionRefusalSentence($0, context: context) }
	}

	@objc func removePressed() {
		guard let folder, let context else {
			return
		}
		let name = context.folderName(folder.folder.root)
		let withdraw = { [weak self] in
			self?.perform { commands throws(WithdrawalRefusal) in
				try await commands.withdrawFolder(folder.folder.identifier)
			} describing: { CollectorRefusalWording.withdrawalRefusalSentence($0) }
		}
		guard renderMode == .interactive, let window = view.window else {
			withdraw()
			return
		}
		let alert = NSAlert()
		alert.messageText = "Stop collecting from \(name)?"
		alert.informativeText = "Your files stay where they are, and Schublade keeps what it received."
		alert.addButton(withTitle: "Remove Folder")
		alert.addButton(withTitle: "Cancel")
		alert.buttons[0].hasDestructiveAction = true
		alert.beginSheetModal(for: window) { response in
			if response == .alertFirstButtonReturn {
				withdraw()
			}
		}
	}

	/// Runs one collector command, keeping the page's buttons off while it runs and showing its
	/// refusal as one sentence. The status that follows a success redraws the page.
	func perform<Refusal: Error>(
		_ command: @escaping (any CollectorCommands) async throws(Refusal) -> Void,
		describing: @escaping (Refusal) -> String
	) {
		commandPending = true
		failure = nil
		rebuild()
		let commands = commands
		Task {
			do throws(Refusal) {
				try await command(commands)
				failure = nil
			} catch {
				failure = describing(error)
			}
			commandPending = false
			rebuild()
		}
	}
}
