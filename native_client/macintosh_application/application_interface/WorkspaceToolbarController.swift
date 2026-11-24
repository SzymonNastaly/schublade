import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// Owns the unified window toolbar. Its items stand over the parts of the workspace's split view
/// they act on, kept there by the system's tracking separators: the sidebar's toggle and Back over
/// the sidebar, Sort over the list, Original and Text, Share, and the search field over the reader,
/// and the inspector's toggle over the inspector. A page that is not about documents shows only
/// what still applies.
final class WorkspaceToolbarController: NSObject {
	private static let backIdentifier = NSToolbarItem.Identifier("schublade.back")
	private static let sortIdentifier = NSToolbarItem.Identifier("schublade.sort")
	private static let listSeparatorIdentifier = NSToolbarItem.Identifier("schublade.listSeparator")
	private static let searchIdentifier = NSToolbarItem.Identifier("schublade.search")
	private static let shareIdentifier = NSToolbarItem.Identifier("schublade.share")
	private static let readerTabIdentifier = NSToolbarItem.Identifier("schublade.readerTab")
	/// The tabs of Original and Text, in the order of the group's items.
	private static let readerTabs: [ReaderTab] = [.original, .text]

	/// When an item of the arrangement shows.
	private enum Presence {
		case always
		case whileBackLeads
		case whileDocumentsShow
	}

	/// Every item the toolbar can show, in the order it shows them. The flexible spaces share an
	/// identifier, so the toolbar's items are tracked by their place in this list.
	private static let arrangement: [(identifier: NSToolbarItem.Identifier, presence: Presence)] = [
		(.toggleSidebar, .always),
		(backIdentifier, .whileBackLeads),
		(.sidebarTrackingSeparator, .always),
		(.flexibleSpace, .whileDocumentsShow),
		(sortIdentifier, .whileDocumentsShow),
		(listSeparatorIdentifier, .whileDocumentsShow),
		(readerTabIdentifier, .whileDocumentsShow),
		(.flexibleSpace, .always),
		(shareIdentifier, .whileDocumentsShow),
		(searchIdentifier, .always),
		(.inspectorTrackingSeparator, .whileDocumentsShow),
		(.flexibleSpace, .whileDocumentsShow),
		(.toggleInspector, .whileDocumentsShow),
	]

	let toolbar = NSToolbar(identifier: NSToolbar.Identifier("org.schublade.libraryToolbar"))
	private let backItem = NSToolbarItem(itemIdentifier: backIdentifier)
	private let sortItem = NSMenuToolbarItem(itemIdentifier: sortIdentifier)
	private let searchItem = NSSearchToolbarItem(itemIdentifier: searchIdentifier)
	private let shareItem = NSSharingServicePickerToolbarItem(itemIdentifier: shareIdentifier)
	private lazy var readerTabGroup = NSToolbarItemGroup(
		itemIdentifier: Self.readerTabIdentifier,
		titles: ["Original", "Text"],
		selectionMode: .selectOne,
		labels: ["Original", "Text"],
		target: self,
		action: #selector(readerTabChosen(_:))
	)
	private let sortMenu = NSMenu()
	/// The places in `arrangement` of the items the toolbar shows now.
	private var shownPlaces: [Int]
	private weak var listSplitView: NSSplitView?

	private let onNavigateBack: () -> Void
	private let onSelectOrder: (ListingOrder) -> Void
	private let onSelectReaderTab: (ReaderTab) -> Void
	private let onSearchTextChanged: (String) -> Void
	private let onMoveFocusToList: (_ selectsFirstDocument: Bool) -> Void
	private let shareableItems: () -> [Any]

	init(
		onNavigateBack: @escaping () -> Void,
		onSelectOrder: @escaping (ListingOrder) -> Void,
		onSelectReaderTab: @escaping (ReaderTab) -> Void,
		onSearchTextChanged: @escaping (String) -> Void,
		onMoveFocusToList: @escaping (_ selectsFirstDocument: Bool) -> Void,
		shareableItems: @escaping () -> [Any]
	) {
		self.onNavigateBack = onNavigateBack
		self.onSelectOrder = onSelectOrder
		self.onSelectReaderTab = onSelectReaderTab
		self.onSearchTextChanged = onSearchTextChanged
		self.onMoveFocusToList = onMoveFocusToList
		self.shareableItems = shareableItems
		shownPlaces = Self.places(showsBackButton: false, showsDocuments: true)
		super.init()
		configureToolbarItems()
		toolbar.delegate = self
		toolbar.displayMode = .iconOnly
		toolbar.allowsUserCustomization = false
	}

	/// The split view whose second divider, between the list and the reader, Sort's section ends at.
	func track(_ splitView: NSSplitView) {
		guard splitView !== listSplitView else {
			return
		}
		listSplitView = splitView
		// The separator takes its split view when the toolbar asks for it, so it is asked again.
		if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.listSeparatorIdentifier }) {
			toolbar.removeItem(at: index)
			toolbar.insertItem(withItemIdentifier: Self.listSeparatorIdentifier, at: index)
		}
	}

	func apply(
		workspace: LibraryWorkspacePresentation,
		navigation: LibraryNavigationState,
		hasSelectedDocument: Bool
	) {
		arrangeItems(Self.places(
			showsBackButton: workspace.showsBackButton,
			showsDocuments: workspace.detailMode == .documents
		))
		sortItem.isEnabled = workspace.allowsSortSelection
		for item in sortMenu.items {
			if let order = Self.order(forTag: item.tag) {
				item.state = order == workspace.effectiveOrder ? .on : .off
			}
		}
		searchItem.searchField.placeholderString = workspace.searchPlaceholder
		if searchItem.searchField.stringValue != navigation.searchText {
			searchItem.searchField.stringValue = navigation.searchText
		}
		shareItem.isEnabled = hasSelectedDocument
		readerTabGroup.isEnabled = hasSelectedDocument
		readerTabGroup.selectedIndex = Self.readerTabs.firstIndex(of: navigation.readerTab) ?? 0
	}

	func focusSearchField() {
		searchItem.beginSearchInteraction()
	}

	private func configureToolbarItems() {
		backItem.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
		backItem.label = "Back"
		backItem.toolTip = "Back"
		backItem.isNavigational = true
		backItem.target = self
		backItem.action = #selector(backPressed)

		configureSortMenu()

		searchItem.searchField.delegate = self
		searchItem.searchField.target = self
		searchItem.searchField.action = #selector(searchFieldSubmitted)
		searchItem.preferredWidthForSearchField = 240
		searchItem.searchField.setAccessibilityIdentifier(InterfaceIdentifier.toolbarSearchField)

		readerTabGroup.label = "View"
		readerTabGroup.toolTip = "Show the Original or the Extracted Text"

		shareItem.label = "Share"
		shareItem.toolTip = "Share Original"
		shareItem.autovalidates = false
		shareItem.delegate = self
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

	/// Removes the items a state does not show and inserts the ones it adds, each at its place in
	/// `arrangement`, so the toolbar never rebuilds the items that stay.
	private func arrangeItems(_ places: [Int]) {
		guard places != shownPlaces else {
			return
		}
		for (index, place) in shownPlaces.enumerated().reversed() where !places.contains(place) {
			toolbar.removeItem(at: index)
		}
		var remaining = shownPlaces.filter { places.contains($0) }
		for (index, place) in places.enumerated() where !remaining.contains(place) {
			toolbar.insertItem(withItemIdentifier: Self.arrangement[place].identifier, at: index)
			remaining.insert(place, at: index)
		}
		shownPlaces = places
	}

	private static func places(showsBackButton: Bool, showsDocuments: Bool) -> [Int] {
		arrangement.indices.filter { place in
			switch arrangement[place].presence {
			case .always: true
			case .whileBackLeads: showsBackButton
			case .whileDocumentsShow: showsDocuments
			}
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

	@objc private func backPressed() {
		onNavigateBack()
	}

	@objc private func sortMenuItemChosen(_ sender: NSMenuItem) {
		guard let order = Self.order(forTag: sender.tag) else {
			return
		}
		onSelectOrder(order)
	}

	@objc private func readerTabChosen(_: Any?) {
		let index = readerTabGroup.selectedIndex
		guard Self.readerTabs.indices.contains(index) else {
			return
		}
		onSelectReaderTab(Self.readerTabs[index])
	}

	@objc private func searchFieldSubmitted() {
		onSearchTextChanged(searchItem.searchField.stringValue)
	}
}

extension WorkspaceToolbarController: NSToolbarDelegate, NSSearchFieldDelegate {
	func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
		shownPlaces.map { Self.arrangement[$0].identifier }
	}

	func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
		Array(Set(Self.arrangement.map(\.identifier)))
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
		case Self.listSeparatorIdentifier:
			listSplitView.map { splitView in
				NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: splitView, dividerIndex: 1)
			}
		case Self.searchIdentifier:
			searchItem
		case Self.shareIdentifier:
			shareItem
		case Self.readerTabIdentifier:
			readerTabGroup
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

	/// Down and Return take the keyboard to the results, as Mail does, and Escape clears the search
	/// and leaves the keyboard with the list, so the workspace's commands stay in the responder chain.
	func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
		guard control === searchItem.searchField else {
			return false
		}
		switch selector {
		case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
			onSearchTextChanged(searchItem.searchField.stringValue)
			onMoveFocusToList(true)
			return true
		case #selector(NSResponder.cancelOperation(_:)):
			searchItem.searchField.stringValue = ""
			onSearchTextChanged("")
			searchItem.endSearchInteraction()
			onMoveFocusToList(false)
			return true
		default:
			return false
		}
	}
}

extension WorkspaceToolbarController: NSSharingServicePickerToolbarItemDelegate {
	func items(for _: NSSharingServicePickerToolbarItem) -> [Any] {
		shareableItems()
	}
}
