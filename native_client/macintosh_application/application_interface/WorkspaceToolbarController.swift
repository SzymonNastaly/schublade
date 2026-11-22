import AppKit
import ApplicationBindings
import ApplicationPresentation

/// Owns the unified window toolbar items (back navigation, sort menu, search field, share, and
/// inspector toggle) and forwards actions to `MainWindowController`.
final class WorkspaceToolbarController: NSObject {
	private static let backIdentifier = NSToolbarItem.Identifier("schublade.back")
	private static let sortIdentifier = NSToolbarItem.Identifier("schublade.sort")
	private static let searchIdentifier = NSToolbarItem.Identifier("schublade.search")
	private static let shareIdentifier = NSToolbarItem.Identifier("schublade.share")
	private static let inspectorIdentifier = NSToolbarItem.Identifier("schublade.inspector")

	let toolbar = NSToolbar(identifier: NSToolbar.Identifier("org.schublade.libraryToolbar"))
	private let backItem = NSToolbarItem(itemIdentifier: backIdentifier)
	private let sortItem = NSMenuToolbarItem(itemIdentifier: sortIdentifier)
	private let searchItem = NSSearchToolbarItem(itemIdentifier: searchIdentifier)
	private let shareItem = NSToolbarItem(itemIdentifier: shareIdentifier)
	private let inspectorItem = NSToolbarItem(itemIdentifier: inspectorIdentifier)
	private let sortMenu = NSMenu()
	private var showsBackButton = false

	private let onNavigateBack: () -> Void
	private let onSelectOrder: (ListingOrder) -> Void
	private let onSearchTextChanged: (String) -> Void
	private let onShareDocument: (NSView) -> Void
	private let onToggleInspector: () -> Void

	init(
		onNavigateBack: @escaping () -> Void,
		onSelectOrder: @escaping (ListingOrder) -> Void,
		onSearchTextChanged: @escaping (String) -> Void,
		onShareDocument: @escaping (NSView) -> Void,
		onToggleInspector: @escaping () -> Void
	) {
		self.onNavigateBack = onNavigateBack
		self.onSelectOrder = onSelectOrder
		self.onSearchTextChanged = onSearchTextChanged
		self.onShareDocument = onShareDocument
		self.onToggleInspector = onToggleInspector
		super.init()
		configureToolbarItems()
		toolbar.delegate = self
		toolbar.displayMode = .iconOnly
		toolbar.allowsUserCustomization = false
	}

	func apply(
		workspace: LibraryWorkspacePresentation,
		navigation: LibraryNavigationState,
		hasSelectedDocument: Bool
	) {
		updateBackButtonVisibility(workspace.showsBackButton)
		sortItem.isEnabled = workspace.allowsSortSelection
		for item in sortMenu.items {
			if let order = Self.order(forTag: item.tag) {
				item.state = order == workspace.effectiveOrder ? .on : .off
			}
		}
		if searchItem.searchField.stringValue != navigation.searchText {
			searchItem.searchField.stringValue = navigation.searchText
		}
		shareItem.isEnabled = hasSelectedDocument
		inspectorItem.isEnabled = workspace.detailMode == .documents
	}

	func focusSearchField() {
		searchItem.beginSearchInteraction()
	}

	private func configureToolbarItems() {
		let backButton = NSButton(
			image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back") ?? NSImage(),
			target: self,
			action: #selector(backButtonPressed)
		)
		backButton.bezelStyle = .texturedRounded
		backButton.setAccessibilityIdentifier(InterfaceIdentifier.toolbarBackButton)
		backItem.label = "Back"
		backItem.toolTip = "Back"
		backItem.view = backButton

		configureSortMenu()

		searchItem.searchField.placeholderString = "Search"
		searchItem.searchField.delegate = self
		searchItem.searchField.target = self
		searchItem.searchField.action = #selector(searchFieldSubmitted)
		searchItem.resignsFirstResponderWithCancel = true
		searchItem.searchField.setAccessibilityIdentifier(InterfaceIdentifier.toolbarSearchField)

		let shareButton = NSButton(
			image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share") ?? NSImage(),
			target: self,
			action: #selector(sharePressed)
		)
		shareButton.bezelStyle = .texturedRounded
		shareButton.setAccessibilityIdentifier(InterfaceIdentifier.toolbarShareButton)
		shareItem.label = "Share"
		shareItem.toolTip = "Share Original"
		shareItem.view = shareButton

		let inspectorButton = NSButton(
			image: NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Inspector") ?? NSImage(),
			target: self,
			action: #selector(inspectorPressed)
		)
		inspectorButton.bezelStyle = .texturedRounded
		inspectorButton.setAccessibilityIdentifier(InterfaceIdentifier.toolbarInspectorButton)
		inspectorItem.label = "Inspector"
		inspectorItem.toolTip = "Show or Hide Inspector"
		inspectorItem.view = inspectorButton
	}

	private func configureSortMenu() {
		let entries: [(String, ListingOrder)] = [
			("Date on Document", .documentDate),
			("Date Added", .addition),
			("Title", .title),
			("Sender", .sender),
		]
		for (index, entry) in entries.enumerated() {
			let menuItem = NSMenuItem(
				title: entry.0,
				action: #selector(sortMenuItemChosen(_:)),
				keyEquivalent: ""
			)
			menuItem.target = self
			menuItem.tag = index
			sortMenu.addItem(menuItem)
		}
		sortItem.label = "Sort By"
		sortItem.toolTip = "Sort Documents"
		sortItem.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort By")
		sortItem.menu = sortMenu
		sortItem.showsIndicator = true
	}

	private func updateBackButtonVisibility(_ visible: Bool) {
		guard visible != showsBackButton else {
			return
		}
		showsBackButton = visible
		if visible {
			toolbar.insertItem(withItemIdentifier: Self.backIdentifier, at: 1)
		} else if let existingIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.backIdentifier }) {
			toolbar.removeItem(at: existingIndex)
		}
	}

	private static func order(forTag tag: Int) -> ListingOrder? {
		switch tag {
		case 0: .documentDate
		case 1: .addition
		case 2: .title
		case 3: .sender
		default: nil
		}
	}

	@objc private func backButtonPressed() {
		onNavigateBack()
	}

	@objc private func sortMenuItemChosen(_ sender: NSMenuItem) {
		guard let order = Self.order(forTag: sender.tag) else {
			return
		}
		onSelectOrder(order)
	}

	@objc private func searchFieldSubmitted() {
		onSearchTextChanged(searchItem.searchField.stringValue)
	}

	@objc private func sharePressed() {
		guard let anchor = shareItem.view else {
			return
		}
		onShareDocument(anchor)
	}

	@objc private func inspectorPressed() {
		onToggleInspector()
	}
}

extension WorkspaceToolbarController: NSToolbarDelegate, NSSearchFieldDelegate {
	func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
		var items: [NSToolbarItem.Identifier] = [.toggleSidebar]
		if showsBackButton {
			items.append(Self.backIdentifier)
		}
		items.append(contentsOf: [
			.sidebarTrackingSeparator,
			Self.sortIdentifier,
			.flexibleSpace,
			Self.searchIdentifier,
			Self.shareIdentifier,
			Self.inspectorIdentifier,
		])
		return items
	}

	func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
		[
			.toggleSidebar,
			Self.backIdentifier,
			.sidebarTrackingSeparator,
			Self.sortIdentifier,
			.flexibleSpace,
			Self.searchIdentifier,
			Self.shareIdentifier,
			Self.inspectorIdentifier,
		]
	}

	func toolbar(
		_: NSToolbar,
		itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
		willBeInsertedIntoToolbar _: Bool
	) -> NSToolbarItem? {
		switch itemIdentifier {
		case Self.backIdentifier:
			backItem
		case Self.sortIdentifier:
			sortItem
		case Self.searchIdentifier:
			searchItem
		case Self.shareIdentifier:
			shareItem
		case Self.inspectorIdentifier:
			inspectorItem
		default:
			nil
		}
	}

	func controlTextDidChange(_ notification: Notification) {
		guard let field = notification.object as? NSSearchField, field === searchItem.searchField else {
			return
		}
		onSearchTextChanged(field.stringValue)
	}
}
