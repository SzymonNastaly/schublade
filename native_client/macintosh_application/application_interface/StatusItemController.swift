import AppKit
import ApplicationBindings
import ApplicationPresentation

/// The menu bar item: the drawer glyph of the application's state, the upload animation, and a
/// menu with the status line, the upload in flight, what needs attention, the five newest
/// documents, Open Schublade, Add Folder…, and Quit.
public final class StatusItemController: NSObject, NSMenuDelegate {
	private static let newestDocumentCount = 5
	private static let frameInterval: TimeInterval = 0.11

	public let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
	private let queries: any LibraryQueries
	private let menu = NSMenu()
	private var presentation = StatusItemPresentation.resolve(situation: .starting, context: .current())
	private var animation = StatusItemAnimation()
	private var frameTimer: Timer?
	private var newestDocuments: [DocumentRow] = []
	private var attentionActions: [AttentionAction] = []
	private var isMenuOpen = false
	private var rebuildPending = false

	var onOpenWindow: (() -> Void)?
	var onOpenAction: ((AttentionAction) -> Void)?
	var onOpenDocument: ((DocumentIdentifier) -> Void)?
	var onAddFolder: (() -> Void)?
	var onOpenSettings: (() -> Void)?

	public init(queries: any LibraryQueries) {
		self.queries = queries
		super.init()
		// AppKit keeps whether the item shows under this name, for Settings and for Command-dragging it away.
		item.autosaveName = "org.schublade.statusItem"
		item.behavior = .removalAllowed
		menu.delegate = self
		menu.autoenablesItems = false
		item.menu = menu
		drawGlyph()
		rebuildMenu()
	}

	public func render(_ situation: ApplicationSituation) {
		let next = StatusItemPresentation.resolve(situation: situation, context: .current())
		guard next != presentation else {
			return
		}
		presentation = next
		animation.follow(next.glyph, reduceMotion: Self.reducesMotion)
		updateTimer()
		drawGlyph()
		rebuildMenu()
	}

	// MARK: The glyph and its animation

	private static var reducesMotion: Bool {
		NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
	}

	private func drawGlyph() {
		let frame = animation.frame(for: presentation.glyph, reduceMotion: Self.reducesMotion)
		let glyph: StatusItemGlyph = frame == nil ? presentation.glyph : .submitting
		item.button?.image = DrawerGlyph.image(glyph, frame: frame)
	}

	/// A timer exists only while a cycle runs, and in the common modes, so it also ticks while the
	/// menu is open.
	private func updateTimer() {
		guard animation.needsTimer else {
			frameTimer?.invalidate()
			frameTimer = nil
			return
		}
		guard frameTimer == nil else {
			return
		}
		let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.advanceFrame()
			}
		}
		RunLoop.main.add(timer, forMode: .common)
		frameTimer = timer
	}

	private func advanceFrame() {
		animation.tick(stillSubmitting: presentation.glyph == .submitting)
		updateTimer()
		drawGlyph()
	}

	// MARK: The menu

	/// Reads the newest documents when the library changes, so they are there before the menu opens.
	public func contentRevisionChanged() {
		Task {
			// The archive's newest documents, however old: Recently Added covers only 30 days.
			let request = ListingRequest.browse(scope: .allDocuments, order: .addition)
			guard let reply = try? await queries.listDocuments(request: request, preceding: nil) else {
				return
			}
			newestDocuments = Self.newestDocuments(in: reply.listing)
			rebuildMenu()
		}
	}

	public func menuWillOpen(_: NSMenu) {
		isMenuOpen = true
	}

	/// A menu rebuilt while it is open loses the row under the pointer, so changes wait for it to close.
	public func menuDidClose(_: NSMenu) {
		isMenuOpen = false
		if rebuildPending {
			rebuildMenu()
		}
	}

	private static func newestDocuments(in listing: any DocumentListingSnapshot) -> [DocumentRow] {
		let rows = listing.rows(first: 0, count: UInt32(newestDocumentCount * 3))
		return Array(rows.compactMap { row in
			if case let .document(document) = row {
				return document
			}
			return nil
		}.prefix(newestDocumentCount))
	}

	private func rebuildMenu() {
		guard !isMenuOpen else {
			rebuildPending = true
			return
		}
		rebuildPending = false
		menu.removeAllItems()
		attentionActions = []
		menu.addItem(disabledItem(presentation.statusSentence))
		if let upload = presentation.uploadSentence {
			menu.addItem(disabledItem(upload))
		}
		if !presentation.attention.isEmpty {
			menu.addItem(.separator())
			for sentence in presentation.attention {
				menu.addItem(attentionItem(sentence))
			}
		}
		if !newestDocuments.isEmpty {
			menu.addItem(.separator())
			menu.addItem(disabledItem("Recently Added"))
			for document in newestDocuments {
				let entry = actionItem(document.title ?? "Untitled Document", #selector(documentChosen(_:)))
				entry.representedObject = document.document.value
				entry.indentationLevel = 1
				menu.addItem(entry)
			}
		}
		menu.addItem(.separator())
		menu.addItem(actionItem("Open Schublade", #selector(openWindow)))
		if presentation.offersAddFolder {
			menu.addItem(actionItem("Add Folder…", #selector(addFolder)))
		}
		menu.addItem(actionItem("Settings…", #selector(openSettings)))
		menu.addItem(.separator())
		menu.addItem(NSMenuItem(
			title: "Quit Schublade",
			action: #selector(NSApplication.terminate(_:)),
			keyEquivalent: "q"
		))
	}

	private func attentionItem(_ sentence: AttentionSentence) -> NSMenuItem {
		guard let action = sentence.action else {
			return disabledItem(sentence.text)
		}
		let entry = actionItem(sentence.text, #selector(attentionChosen(_:)))
		entry.tag = attentionActions.count
		attentionActions.append(action)
		return entry
	}

	private func disabledItem(_ title: String) -> NSMenuItem {
		let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
		entry.isEnabled = false
		return entry
	}

	private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
		let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
		entry.target = self
		return entry
	}

	/// The rows of the menu as text, for the renderer's files and for tests.
	public var menuTitles: [String] {
		menu.items.map { entry in
			entry.isSeparatorItem ? "──────────────" : String(repeating: "\t", count: entry.indentationLevel) + entry
				.title
		}
	}

	@objc private func openWindow() {
		onOpenWindow?()
	}

	@objc private func addFolder() {
		onAddFolder?()
	}

	@objc private func openSettings() {
		onOpenSettings?()
	}

	@objc private func attentionChosen(_ sender: NSMenuItem) {
		guard attentionActions.indices.contains(sender.tag) else {
			return
		}
		onOpenAction?(attentionActions[sender.tag])
	}

	@objc private func documentChosen(_ sender: NSMenuItem) {
		guard let identifier = sender.representedObject as? String else {
			return
		}
		onOpenDocument?(DocumentIdentifier(value: identifier))
	}
}
