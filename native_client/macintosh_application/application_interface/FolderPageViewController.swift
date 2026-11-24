import AppKit
import ApplicationBindings
import ApplicationPresentation
import UniformTypeIdentifiers

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

	/// A command in flight: the folder it is for and the admission it found, so its result never
	/// lands on another folder's page and the buttons stay off until the status shows the change.
	private struct PendingCommand {
		let folder: FolderIdentifier
		let admission: Int
	}

	private let commands: any CollectorCommands
	private let renderMode: InterfaceRenderMode
	private let onSelectDocument: (DocumentIdentifier) -> Void
	private let onFolderWithdrawn: () -> Void
	private let page = PageColumnView()
	private var shown: Shown?
	private var stateDetail: NSTextField?
	private var folder: FolderStatus?
	private var receipts: [Receipt] = []
	private var context: ApplicationWordingContext?
	private var failure: String?
	private var pending: PendingCommand?

	var commandPending: Bool {
		pending != nil && pending?.folder == folder?.folder.identifier
	}

	init(
		commands: any CollectorCommands,
		renderMode: InterfaceRenderMode,
		onSelectDocument: @escaping (DocumentIdentifier) -> Void,
		onFolderWithdrawn: @escaping () -> Void
	) {
		self.commands = commands
		self.renderMode = renderMode
		self.onSelectDocument = onSelectDocument
		self.onFolderWithdrawn = onFolderWithdrawn
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func requestRemoval() {
		guard !commandPending else {
			return
		}
		removePressed()
	}

	override func loadView() {
		view = page
	}

	func render(folder: FolderStatus?, receipts: [Receipt], context: ApplicationWordingContext) {
		let admission = folder.map { Self.kind(of: $0.admission) }
		let changed = folder?.folder.identifier != self.folder?.folder.identifier
			|| folder?.unavailability != self.folder?.unavailability
			|| admission != self.folder.map { Self.kind(of: $0.admission) }
		if changed {
			failure = nil
		}
		// The status shows the command's effect, so the buttons may come back.
		if let pending, pending.folder == folder?.folder.identifier, pending.admission != admission {
			self.pending = nil
		}
		self.folder = folder
		self.receipts = receipts
		self.context = context
		rebuild()
	}

	private func rebuild() {
		guard let folder, let context else {
			// A folder just added, or opened from a notification before the first status, is listed soon.
			page.show([PageText.body("Opening the folder…", color: .secondaryLabelColor)])
			shown = nil
			return
		}
		let next = Shown(
			folder: Self.withoutProgress(folder),
			receipts: receipts,
			failure: failure,
			commandPending: commandPending
		)
		guard next != shown else {
			// During a survey only the count of files under examination moves; it changes in place.
			stateDetail?.stringValue = CollectorWording.folderState(folder).detail ?? ""
			return
		}
		shown = next
		let name = context.folderName(folder.folder.root)
		var views: [NSView] = [header(name: name, folder: folder), stateLine(CollectorWording.folderState(folder))]
		switch folder.admission {
		case .surveying:
			views.append(PageText.secondary(Self.collectionNote))
		case let .awaitingDecision(backlog):
			views += confirmation(BacklogConfirmationWording.make(folderName: name, backlog: backlog))
		case .collecting:
			if !receipts.isEmpty {
				views.append(recentUploads(context: context))
			}
			views.append(PageText.secondary(Self.collectionNote))
		}
		if let failure {
			let label = PageText.body(failure, color: InterfacePalette.attention)
			label.setAccessibilityIdentifier(InterfaceIdentifier.folderPageFailure)
			views.append(label)
		}
		page.show(views)
	}

	/// The case of an admission, without the counts that change while it lasts.
	private static func kind(of admission: FolderAdmission) -> Int {
		switch admission {
		case .surveying:
			0
		case .awaitingDecision:
			1
		case .collecting:
			2
		}
	}

	private static func withoutProgress(_ folder: FolderStatus) -> FolderStatus {
		var structure = folder
		if case .surveying = folder.admission {
			structure.admission = .surveying(filesUnderExamination: 0)
		}
		return structure
	}

	static let collectionNote = "Schublade reads the PDF, JPEG, PNG, and WebP files in this folder and its "
		+ "subfolders. It never changes, moves, or deletes your files, and removing the folder keeps what Schublade "
		+ "received."
}

extension FolderPageViewController {
	/// The folder as Finder shows it: its own icon, its name, a path to click, and a More menu.
	func header(name: String, folder: FolderStatus) -> NSView {
		let icon = NSImageView(image: folderIcon(folder.folder.root))
		icon.imageScaling = .scaleProportionallyUpOrDown
		icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
		icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

		let title = PageText.title(name)
		title.setAccessibilityIdentifier(InterfaceIdentifier.folderPageTitle)
		let path = NSPathControl()
		path.url = URL(fileURLWithPath: folder.folder.root, isDirectory: true)
		path.pathStyle = .standard
		path.isEditable = false
		path.backgroundColor = .clear
		path.font = NSFont.preferredFont(forTextStyle: .subheadline)
		path.target = self
		path.doubleAction = #selector(pathComponentChosen(_:))
		path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		path.setAccessibilityIdentifier(InterfaceIdentifier.folderPagePath)
		let names = NSStackView(views: [title, path])
		names.orientation = .vertical
		names.alignment = .leading
		names.spacing = 2
		names.setContentHuggingPriority(.defaultLow, for: .horizontal)

		let row = NSStackView(views: [icon, names, moreButton()])
		row.distribution = .fill
		row.alignment = .centerY
		row.spacing = 12
		return row
	}

	func folderIcon(_ root: String) -> NSImage {
		// Offscreen the folder is a made-up path, which would draw as a blank document.
		renderMode == .interactive
			? NSWorkspace.shared.icon(forFile: root)
			: NSWorkspace.shared.icon(for: .folder)
	}

	func moreButton() -> NSPopUpButton {
		let more = NSPopUpButton(frame: .zero, pullsDown: true)
		more.bezelStyle = .push
		more.isBordered = false
		(more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
		let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
		face.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")?
			.withSymbolConfiguration(NSImage.SymbolConfiguration(textStyle: .title2))
		more.menu?.addItem(face)
		for (title, symbol, action) in [
			("Show in Finder", "folder", #selector(showInFinderPressed)),
			("Remove Folder…", "minus.circle", #selector(removePressed)),
		] {
			let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
			item.target = self
			item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
			more.menu?.addItem(item)
		}
		more.isEnabled = !commandPending
		more.toolTip = "More"
		more.setAccessibilityLabel("More")
		more.setContentHuggingPriority(.required, for: .horizontal)
		more.setAccessibilityIdentifier(InterfaceIdentifier.folderPageMoreButton)
		return more
	}

	func stateLine(_ state: FolderStatePresentation) -> NSView {
		let label = NSTextField(labelWithString: state.label)
		label.font = NSFont.systemFont(
			ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
			weight: .semibold
		)
		label.textColor = PageText.color(of: state.tone)
		label.setAccessibilityIdentifier(InterfaceIdentifier.folderPageState)
		let line = NSStackView(views: [PageText.mark(state.mark, tone: state.tone, description: state.label), label])
		line.spacing = 6
		guard let detail = state.detail else {
			stateDetail = nil
			return line
		}
		let detailLabel = PageText.body(detail)
		stateDetail = detailLabel
		var rows: [NSView] = [line, detailLabel]
		if folder?.unavailability == .accessDenied {
			let settings = NSButton(
				title: "Open System Settings…",
				target: self,
				action: #selector(openPrivacySettings)
			)
			settings.bezelStyle = .push
			rows.append(settings)
		}
		let block = NSStackView(views: rows)
		block.orientation = .vertical
		block.alignment = .leading
		block.spacing = 4
		return block
	}

	func recentUploads(context: ApplicationWordingContext) -> NSView {
		let group = PageRowGroupView(heading: "Recently Uploaded from This Mac")
		for receipt in receipts.prefix(8) {
			group.appendRow(receiptRow(receipt, context: context))
		}
		return group
	}

	/// The outcome's mark, the file's name, and at the trailing edge the outcome where the mark
	/// does not say it, and the time.
	func receiptRow(_ receipt: Receipt, context: ApplicationWordingContext) -> NSView {
		let outcome = CollectorWording.receiptOutcome(receipt.outcome)
		let mark = PageText.mark(outcome.mark, tone: outcome.tone, description: outcome.label)
		mark.widthAnchor.constraint(equalToConstant: 18).isActive = true
		let name = NSButton(title: receipt.fileName, target: self, action: #selector(receiptPressed(_:)))
		name.isBordered = false
		name.alignment = .left
		name.font = NSFont.preferredFont(forTextStyle: .body)
		name.contentTintColor = .labelColor
		name.lineBreakMode = .byTruncatingMiddle
		name.identifier = NSUserInterfaceItemIdentifier(receipt.documentIdentifier)
		name.setContentHuggingPriority(.defaultLow, for: .horizontal)
		name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		var views: [NSView] = [mark, name]
		if outcome.showsLabel {
			views.append(PageText.figure(outcome.label, color: PageText.color(of: outcome.tone)))
		}
		views.append(PageText.figure(CollectorWording.receiptTime(receipt.receivedAt, context: context)))
		let row = NSStackView(views: views)
		row.distribution = .fill
		row.spacing = 8
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
			self?.perform(
				{ commands throws(WithdrawalRefusal) in try await commands.withdrawFolder(folder.folder.identifier) },
				withdrawing: true,
				describing: { CollectorRefusalWording.withdrawalRefusalSentence($0) }
			)
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
		withdrawing: Bool = false,
		describing: @escaping (Refusal) -> String
	) {
		guard let folder, !commandPending else {
			return
		}
		let target = folder.folder.identifier
		pending = PendingCommand(folder: target, admission: Self.kind(of: folder.admission))
		failure = nil
		rebuild()
		let commands = commands
		Task {
			do throws(Refusal) {
				try await command(commands)
				if withdrawing, self.folder?.folder.identifier == target {
					pending = nil
					onFolderWithdrawn()
				}
			} catch {
				if pending?.folder == target {
					pending = nil
				}
				if self.folder?.folder.identifier == target {
					failure = describing(error)
				}
			}
			rebuild()
		}
	}

	@objc func showInFinderPressed() {
		guard let folder else {
			return
		}
		NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.folder.root, isDirectory: true)])
	}

	@objc func pathComponentChosen(_ sender: NSPathControl) {
		if let url = sender.clickedPathItem?.url {
			NSWorkspace.shared.activateFileViewerSelecting([url])
		}
	}

	@objc func openPrivacySettings() {
		let address = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
		if let settings = URL(string: address) {
			NSWorkspace.shared.open(settings)
		}
	}
}
