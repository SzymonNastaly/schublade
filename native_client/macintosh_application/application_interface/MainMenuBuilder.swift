import AppKit

/// Builds the full macOS main menu with keyboard shortcuts targeting the active responder chain.
enum MainMenuBuilder {
	static func installMainMenu() {
		let mainMenu = NSMenu()
		mainMenu.addItem(makeApplicationMenu())
		mainMenu.addItem(makeFileMenu())
		mainMenu.addItem(makeEditMenu())
		mainMenu.addItem(makeViewMenu())
		mainMenu.addItem(makeWindowMenu())
		NSApp.mainMenu = mainMenu
	}

	private static func makeApplicationMenu() -> NSMenuItem {
		let root = NSMenuItem()
		let menu = NSMenu()
		menu.addItem(
			withTitle: "About Schublade",
			action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
			keyEquivalent: ""
		)
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
		let hideOthers = NSMenuItem(
			title: "Hide Others",
			action: #selector(NSApplication.hideOtherApplications(_:)),
			keyEquivalent: "h"
		)
		hideOthers.keyEquivalentModifierMask = [.command, .option]
		menu.addItem(hideOthers)
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

	private static func makeFileMenu() -> NSMenuItem {
		let root = NSMenuItem()
		let menu = NSMenu(title: "File")

		let addFolder = NSMenuItem(
			title: "Add Folder…",
			action: #selector(LibraryWorkspaceViewController.enrollFolderAction(_:)),
			keyEquivalent: "O"
		)
		addFolder.keyEquivalentModifierMask = [.command, .shift]
		menu.addItem(addFolder)
		menu.addItem(.separator())

		menu.addItem(
			withTitle: "Open Original",
			action: #selector(LibraryWorkspaceViewController.openSelectedDocumentDefaultApplication(_:)),
			keyEquivalent: ""
		)
		menu.addItem(
			withTitle: "Quick Look",
			action: #selector(LibraryWorkspaceViewController.toggleQuickLookAction(_:)),
			keyEquivalent: ""
		)

		let openBrowser = NSMenuItem(
			title: "Open in Browser",
			action: #selector(LibraryWorkspaceViewController.openSelectedDocumentInBrowser(_:)),
			keyEquivalent: "b"
		)
		openBrowser.keyEquivalentModifierMask = [.command, .option]
		menu.addItem(openBrowser)

		let exportOriginal = NSMenuItem(
			title: "Export Original…",
			action: #selector(LibraryWorkspaceViewController.exportSelectedDocument(_:)),
			keyEquivalent: "E"
		)
		exportOriginal.keyEquivalentModifierMask = [.command, .shift]
		menu.addItem(exportOriginal)

		menu.addItem(.separator())
		menu.addItem(
			withTitle: "Close Window",
			action: #selector(NSWindow.performClose(_:)),
			keyEquivalent: "w"
		)
		root.submenu = menu
		return root
	}

	private static func makeEditMenu() -> NSMenuItem {
		let root = NSMenuItem()
		let menu = NSMenu(title: "Edit")
		menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
		menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
		menu.addItem(.separator())
		menu.addItem(
			withTitle: "Find…",
			action: #selector(LibraryWorkspaceViewController.focusSearchFieldAction(_:)),
			keyEquivalent: "f"
		)
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

		let toggleSidebar = NSMenuItem(
			title: "Toggle Sidebar",
			action: #selector(LibraryWorkspaceViewController.toggleWorkspaceSidebar(_:)),
			keyEquivalent: "s"
		)
		toggleSidebar.keyEquivalentModifierMask = [.command, .control]
		menu.addItem(toggleSidebar)

		let toggleInspector = NSMenuItem(
			title: "Toggle Inspector",
			action: #selector(LibraryWorkspaceViewController.toggleDocumentInspector(_:)),
			keyEquivalent: "i"
		)
		toggleInspector.keyEquivalentModifierMask = [.command, .option]
		menu.addItem(toggleInspector)

		menu.addItem(.separator())
		menu.addItem(
			withTitle: "Synchronize Now",
			action: #selector(LibraryWorkspaceViewController.synchronizeLibrary(_:)),
			keyEquivalent: "r"
		)
		root.submenu = menu
		return root
	}

	private static func makeSortMenuItem() -> NSMenuItem {
		let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
		let sortMenu = NSMenu(title: "Sort By")
		let entries: [(String, Int)] = [
			("Date on Document", 0),
			("Date Added", 1),
			("Title", 2),
			("Sender", 3),
		]
		for (title, tag) in entries {
			let entry = NSMenuItem(
				title: title,
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
			withTitle: "Bring All to Front",
			action: #selector(NSApplication.arrangeInFront(_:)),
			keyEquivalent: ""
		)
		root.submenu = menu
		return root
	}
}
