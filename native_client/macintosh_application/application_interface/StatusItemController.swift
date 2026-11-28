import AppKit
import ApplicationBindings
import ApplicationPresentation

/// The menu bar item: the drawer glyph of the application's state, the upload animation, and a
/// menu with the status line, one line for the uploads, what needs attention, the five newest
/// documents with their senders, Open Schublade, Add Folder…, Check for Updates… when the
/// application updates itself, Settings…, and Quit.
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
	/// Set only when the application updates itself, which adds Check for Updates… to the menu.
	var onCheckForUpdates: (() -> Void)? {
		didSet { rebuildMenu() }
	}

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
		menu.addItem(disabledItem(presentation.statusSentence, symbolName: presentation.statusSymbolName))
		if let upload = presentation.uploadSentence {
			menu.addItem(disabledItem(upload, symbolName: "arrow.up.circle"))
		}
		if !presentation.attention.isEmpty {
			menu.addItem(.separator())
			for sentence in presentation.attention {
				menu.addItem(attentionItem(sentence))
			}
		}
		if !newestDocuments.isEmpty {
			menu.addItem(.separator())
			menu.addItem(.sectionHeader(title: "Recently Added"))
			for document in newestDocuments {
				menu.addItem(documentItem(document))
			}
		}
		menu.addItem(.separator())
		menu.addItem(actionItem("Open Schublade", symbolName: "macwindow", #selector(openWindow)))
		if presentation.offersAddFolder {
			menu.addItem(actionItem("Add Folder…", symbolName: "folder.badge.plus", #selector(addFolder)))
		}
		if onCheckForUpdates != nil {
			menu.addItem(actionItem("Check for Updates…", symbolName: nil, #selector(checkForUpdates)))
		}
		menu.addItem(actionItem("Settings…", symbolName: nil, #selector(openSettings)))
		menu.addItem(.separator())
		menu.addItem(NSMenuItem(
			title: "Quit Schublade",
			action: #selector(NSApplication.terminate(_:)),
			keyEquivalent: "q"
		))
		item.button?.setAccessibilityTitle("Schublade, \(presentation.statusSentence)")
	}

	private func documentItem(_ document: DocumentRow) -> NSMenuItem {
		let entry = actionItem(
			document.title ?? "Untitled Document",
			symbolName: "doc.text",
			#selector(documentChosen(_:))
		)
		entry.representedObject = document.document.value
		if #available(macOS 14.4, *) {
			entry.subtitle = StatusItemPresentation.documentSubtitle(document, context: .current())
		}
		return entry
	}

	private func attentionItem(_ sentence: AttentionSentence) -> NSMenuItem {
		let symbolName = "exclamationmark.triangle.fill"
		guard let action = sentence.action else {
			return disabledItem(sentence.text, symbolName: symbolName)
		}
		let entry = actionItem(sentence.text, symbolName: symbolName, #selector(attentionChosen(_:)))
		entry.tag = attentionActions.count
		attentionActions.append(action)
		return entry
	}

	private func disabledItem(_ title: String, symbolName: String) -> NSMenuItem {
		let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
		entry.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
		entry.isEnabled = false
		return entry
	}

	private func actionItem(_ title: String, symbolName: String?, _ action: Selector) -> NSMenuItem {
		let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
		entry.target = self
		entry.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
		return entry
	}

	/// The rows of the menu as text, for the renderer's files and for tests: a section header in
	/// capitals, "[symbol]" before a row that shows one, and a subtitle on the next line.
	public var menuTitles: [String] {
		menu.items.map { entry in
			if entry.isSeparatorItem {
				return "──────────────"
			}
			if entry.isSectionHeader {
				return entry.title.uppercased()
			}
			let symbol = entry.image == nil ? "" : "[symbol] "
			var line = symbol + entry.title
			if #available(macOS 14.4, *), let subtitle = entry.subtitle {
				line += "\n" + String(repeating: " ", count: symbol.count) + subtitle
			}
			return line
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

	@objc private func checkForUpdates() {
		onCheckForUpdates?()
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
