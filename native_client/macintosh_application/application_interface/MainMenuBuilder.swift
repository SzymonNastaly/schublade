import AppKit
import ApplicationPresentation

/// Builds the main menu. Every command of the window is here under the name it has elsewhere, the
/// application's own items carry a symbol as the system's do, and the Help menu lets a person
/// search them.
enum MainMenuBuilder {
	private typealias Workspace = LibraryWorkspaceViewController

	/// Rebuilds File > Share for the selected document each time the File menu opens; the menu keeps
	/// only a weak reference to its delegate.
	private static var shareMenuUpdater: ShareMenuUpdater?

	static func installMainMenu(offersUpdates: Bool, shareableItems: @escaping () -> [Any]) {
		NSWindow.allowsAutomaticWindowTabbing = false
		let mainMenu = NSMenu()
		mainMenu.addItem(makeApplicationMenu(offersUpdates: offersUpdates))
		mainMenu.addItem(makeFileMenu(shareableItems: shareableItems))
		mainMenu.addItem(makeEditMenu())
		mainMenu.addItem(makeViewMenu())
		let window = makeWindowMenu()
		mainMenu.addItem(window)
		let help = makeHelpMenu()
		mainMenu.addItem(help)
		NSApp.mainMenu = mainMenu
		NSApp.windowsMenu = window.submenu
		NSApp.helpMenu = help.submenu
	}

	private static func makeApplicationMenu(offersUpdates: Bool) -> NSMenuItem {
		let root = NSMenuItem()
		let menu = NSMenu()
		menu.addItem(
			withTitle: "About Schublade",
			action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
			keyEquivalent: ""
		)
		if offersUpdates {
			menu.addItem(
				withTitle: "Check for Updates…",
				action: #selector(ApplicationDelegate.checkForUpdates(_:)),
				keyEquivalent: ""
			)
		}
		menu.addItem(.separator())
		menu.addItem(
			withTitle: "Settings…",
			action: #selector(ApplicationDelegate.showSettings(_:)),
			keyEquivalent: ","
		)
		menu.addItem(.separator())
		menu.addItem(
			withTitle: "Hide Schublade",
			action: #selector(NSApplication.hide(_:)),
			keyEquivalent: "h"
		)
		menu.addItem(item(
			"Hide Others",
			#selector(NSApplication.hideOtherApplications(_:)),
			key: "h",
			modifiers: [.command, .option]
		))
		menu.addItem(
			withTitle: "Show All",
			action: #selector(NSApplication.unhideAllApplications(_:)),
			keyEquivalent: ""
		)
		menu.addItem(.separator())
		menu.addItem(
			withTitle: "Quit Schublade",
			action: #selector(NSApplication.terminate(_:)),
			keyEquivalent: "q"
		)
		root.submenu = menu
		return root
	}

	private static func makeFileMenu(shareableItems: @escaping () -> [Any]) -> NSMenuItem {
		let root = NSMenuItem()
		let menu = NSMenu(title: "File")
		let updater = ShareMenuUpdater(shareableItems: shareableItems)
		shareMenuUpdater = updater
		menu.delegate = updater
		menu.items = [
			item(
				"Add Folder…",
				#selector(Workspace.enrollFolderAction(_:)),
				key: "O",
				modifiers: [.command, .shift],
				symbol: "folder.badge.plus"
			),
			item("Remove Folder…", #selector(Workspace.removeShownFolderAction(_:)), symbol: "minus.circle"),
			.separator(),
			item(
				"Open Original",
				#selector(Workspace.openSelectedDocumentDefaultApplication(_:)),
				key: "o",
				symbol: "arrow.up.forward.app"
			),
			item("Quick Look", #selector(Workspace.toggleQuickLookAction(_:)), key: "y", symbol: "eye"),
			updater.shareItem,
			item(
				"Export Original…",
				#selector(Workspace.exportSelectedDocument(_:)),
				key: "E",
				modifiers: [.command, .shift],
				symbol: "square.and.arrow.down"
			),
			item(
				"Open in Browser",
				#selector(Workspace.openSelectedDocumentInBrowser(_:)),
				key: "b",
				modifiers: [.command, .option],
				symbol: "safari"
			),
			.separator(),
			item("Close Window", #selector(NSWindow.performClose(_:)), key: "w"),
		]
		root.submenu = menu
		return root
	}

	private static func makeEditMenu() -> NSMenuItem {
		let root = NSMenuItem()
		let menu = NSMenu(title: "Edit")
		menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
		menu.addItem(item("Redo", Selector(("redo:")), key: "Z", modifiers: [.command, .shift]))
		menu.addItem(.separator())
		menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
		menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
		menu.addItem(.separator())

		let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
		let findMenu = NSMenu(title: "Find")
		findMenu.addItem(
			withTitle: "Search",
			action: #selector(LibraryWorkspaceViewController.focusSearchFieldAction(_:)),
			keyEquivalent: "f"
		)
		findMenu.addItem(
			withTitle: "Find Next",
			action: #selector(MainWindowController.findNextMatch(_:)),
			keyEquivalent: "g"
		)
		findMenu.addItem(item(
			"Find Previous",
			#selector(MainWindowController.findPreviousMatch(_:)),
			key: "G",
			modifiers: [.command, .shift]
		))
		find.submenu = findMenu
		menu.addItem(find)
		root.submenu = menu
		return root
	}

	private static func makeViewMenu() -> NSMenuItem {
		let root = NSMenuItem()
		let menu = NSMenu(title: "View")
		menu.addItem(
			withTitle: "Original",
			action: #selector(LibraryWorkspaceViewController.showOriginalRepresentation(_:)),
			keyEquivalent: "1"
		)
		menu.addItem(
			withTitle: "Text",
			action: #selector(LibraryWorkspaceViewController.showExtractedTextRepresentation(_:)),
			keyEquivalent: "2"
		)
		menu.addItem(.separator())
		menu.addItem(makeSortMenuItem())
		menu.addItem(.separator())
		menu.addItem(item(
			"Hide Sidebar",
			#selector(NSSplitViewController.toggleSidebar(_:)),
			key: "s",
			modifiers: [.command, .control]
		))
		menu.addItem(item(
			"Hide Inspector",
			#selector(NSSplitViewController.toggleInspector(_:)),
			key: "i",
			modifiers: [.command, .option]
		))
		menu.addItem(.separator())
		menu.addItem(item(
			"Synchronize Now",
			#selector(LibraryWorkspaceViewController.synchronizeLibrary(_:)),
			key: "r",
			symbol: "arrow.clockwise"
		))
		menu.addItem(item(
			"Enter Full Screen",
			#selector(NSWindow.toggleFullScreen(_:)),
			key: "f",
			modifiers: [.command, .control]
		))
		root.submenu = menu
		return root
	}

	private static func makeSortMenuItem() -> NSMenuItem {
		let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
		let sortMenu = NSMenu(title: "Sort By")
		for (tag, choice) in SortOrderMenu.entries.enumerated() {
			let entry = NSMenuItem(
				title: choice.title,
				action: #selector(LibraryWorkspaceViewController.selectSortOrder(_:)),
				keyEquivalent: ""
			)
			entry.tag = tag
			sortMenu.addItem(entry)
		}
		sortItem.submenu = sortMenu
		return sortItem
	}

	private static func makeWindowMenu() -> NSMenuItem {
		let root = NSMenuItem()
		let menu = NSMenu(title: "Window")
		menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
		menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
		menu.addItem(.separator())
		menu.addItem(
			withTitle: "Library",
			action: #selector(ApplicationDelegate.showLibraryWindow(_:)),
			keyEquivalent: "0"
		)
		menu.addItem(.separator())
		menu.addItem(
			withTitle: "Bring All to Front",
			action: #selector(NSApplication.arrangeInFront(_:)),
			keyEquivalent: ""
		)
		root.submenu = menu
		return root
	}

	/// An empty menu that the system fills with its search of the menus.
	private static func makeHelpMenu() -> NSMenuItem {
		let root = NSMenuItem()
		root.submenu = NSMenu(title: "Help")
		return root
	}

	private static func item(
		_ title: String,
		_ action: Selector,
		key: String = "",
		modifiers: NSEvent.ModifierFlags = .command,
		symbol: String? = nil
	) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
		item.keyEquivalentModifierMask = modifiers
		item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
		return item
	}
}

/// Gives File > Share the system's share menu for the selected document's original each time the
/// File menu opens, and a disabled Share while no original is at hand.
private final class ShareMenuUpdater: NSObject, NSMenuDelegate {
	private let shareableItems: () -> [Any]
	private(set) var shareItem: NSMenuItem

	init(shareableItems: @escaping () -> [Any]) {
		self.shareableItems = shareableItems
		shareItem = Self.unavailableShareItem()
		super.init()
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		let items = shareableItems()
		let replacement = items.isEmpty
			? Self.unavailableShareItem()
			: NSSharingServicePicker(items: items).standardShareMenuItem
		replacement.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
		let index = menu.index(of: shareItem)
		if index >= 0 {
			menu.removeItem(at: index)
			menu.insertItem(replacement, at: index)
		}
		shareItem = replacement
	}

	private static func unavailableShareItem() -> NSMenuItem {
		let item = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
		item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
		item.isEnabled = false
		return item
	}
}
