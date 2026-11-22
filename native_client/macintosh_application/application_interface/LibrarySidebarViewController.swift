import AppKit
import ApplicationPresentation

/// Sidebar navigation source list and bottom status line.
final class LibrarySidebarViewController: NSViewController {
	private static let collapsedSectionsKey = "org.schublade.sidebarCollapsedSections"
	private static let sectionCellIdentifier = NSUserInterfaceItemIdentifier("sidebarSectionCell")
	private static let itemCellIdentifier = NSUserInterfaceItemIdentifier("sidebarItemCell")

	private let renderMode: InterfaceRenderMode
	private let persistsCollapsedState: Bool
	private let onSelectDestination: (NavigationDestination) -> Void
	private let onRequestAddFolder: () -> Void
	private let onStatusLineAction: (StatusLinePresentation) -> Void

	private let outlineView = NSOutlineView()
	private let scrollView = NSScrollView()
	private let bottomSeparator = NSBox()
	private let statusBarView = SidebarStatusBarView()

	private var currentPresentation: SidebarPresentation?
	private var currentStatusLine: StatusLinePresentation?
	private var sectionNodes: [SidebarSectionNode] = []
	private var sectionNodesById: [String: SidebarSectionNode] = [:]
	private var itemNodesById: [String: SidebarItemNode] = [:]
	private var selectedDestination = NavigationDestination.library(.allDocuments, title: nil)
	private var isUpdatingOutline = false
	private var collapsedSectionIds: Set<String>

	var focusTargetView: NSView {
		outlineView
	}

	init(
		renderMode: InterfaceRenderMode = .interactive,
		persistsCollapsedState: Bool = true,
		onSelectDestination: @escaping (NavigationDestination) -> Void,
		onRequestAddFolder: @escaping () -> Void,
		onStatusLineAction: @escaping (StatusLinePresentation) -> Void
	) {
		self.renderMode = renderMode
		self.persistsCollapsedState = persistsCollapsedState
		self.onSelectDestination = onSelectDestination
		self.onRequestAddFolder = onRequestAddFolder
		self.onStatusLineAction = onStatusLineAction
		collapsedSectionIds = persistsCollapsedState
			? Set(UserDefaults.standard.stringArray(forKey: Self.collapsedSectionsKey) ?? [])
			: []
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 214, height: 600))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		configureOutlineView()
		configureLayout()
		applyOffscreenAppearanceIfNeeded()
	}

	func render(_ presentation: SidebarPresentation, selectedDestination: NavigationDestination) {
		self.selectedDestination = selectedDestination
		currentStatusLine = presentation.statusLine
		statusBarView.render(presentation.statusLine) { [weak self] in
			guard let self, let line = currentStatusLine else {
				return
			}
			onStatusLineAction(line)
		}

		guard presentation != currentPresentation else {
			applySelection(for: selectedDestination)
			return
		}
		let previousStructure = sectionNodes.map { ($0.presentation.id, $0.itemNodes.map(\.presentation.id)) }
		let nextStructure = presentation.sections.map { ($0.id, $0.items.map(\.id)) }
		let structureChanged = !structuresMatch(previousStructure, nextStructure)

		currentPresentation = presentation
		synchronizeNodes(with: presentation.sections)

		isUpdatingOutline = true
		if structureChanged {
			outlineView.reloadData()
			restoreExpandedSections()
		} else {
			for section in sectionNodes {
				outlineView.reloadItem(section, reloadChildren: false)
				for item in section.itemNodes {
					outlineView.reloadItem(item, reloadChildren: false)
				}
			}
		}
		applySelection(for: selectedDestination)
		isUpdatingOutline = false
	}

	private func configureOutlineView() {
		let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebarColumn"))
		column.resizingMask = .autoresizingMask
		outlineView.addTableColumn(column)
		outlineView.outlineTableColumn = column
		outlineView.headerView = nil
		outlineView.rowSizeStyle = .default
		outlineView.floatsGroupRows = false
		outlineView.style = renderMode == .offscreenSnapshot ? .plain : .sourceList
		outlineView.dataSource = self
		outlineView.delegate = self
		outlineView.setAccessibilityIdentifier(InterfaceIdentifier.sidebarOutline)

		scrollView.documentView = outlineView
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = renderMode == .offscreenSnapshot
		scrollView.translatesAutoresizingMaskIntoConstraints = false

		bottomSeparator.boxType = .separator
		bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
		statusBarView.translatesAutoresizingMaskIntoConstraints = false
	}

	private func configureLayout() {
		view.addSubview(scrollView)
		view.addSubview(bottomSeparator)
		view.addSubview(statusBarView)

		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: view.topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
			bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			bottomSeparator.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),
			statusBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			statusBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			statusBarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])
	}

	private func applyOffscreenAppearanceIfNeeded() {
		guard renderMode == .offscreenSnapshot else {
			return
		}
		let sidebarColor = NSColor(name: nil) { appearance in
			let match = appearance.bestMatch(from: [.darkAqua, .aqua])
			if match == .darkAqua {
				return NSColor(calibratedWhite: 0.16, alpha: 1)
			}
			return NSColor(calibratedWhite: 0.94, alpha: 1)
		}
		outlineView.backgroundColor = sidebarColor
		scrollView.backgroundColor = sidebarColor
	}

	private func structuresMatch(
		_ lhs: [(String, [String])],
		_ rhs: [(String, [String])]
	) -> Bool {
		guard lhs.count == rhs.count else {
			return false
		}
		for (left, right) in zip(lhs, rhs) where left.0 != right.0 || left.1 != right.1 {
			return false
		}
		return true
	}

	private func synchronizeNodes(with sections: [SidebarSectionPresentation]) {
		sectionNodes = sections.map { section in
			let items = section.items.map { item -> SidebarItemNode in
				if let existing = itemNodesById[item.id] {
					existing.presentation = item
					return existing
				}
				let node = SidebarItemNode(presentation: item)
				itemNodesById[item.id] = node
				return node
			}
			if let existingSection = sectionNodesById[section.id] {
				existingSection.presentation = section
				existingSection.itemNodes = items
				return existingSection
			}
			let node = SidebarSectionNode(presentation: section, itemNodes: items)
			sectionNodesById[section.id] = node
			return node
		}
	}

	private func restoreExpandedSections() {
		for section in sectionNodes {
			if collapsedSectionIds.contains(section.presentation.id) {
				outlineView.collapseItem(section)
			} else {
				outlineView.expandItem(section)
			}
		}
	}

	private func applySelection(for destination: NavigationDestination) {
		isUpdatingOutline = true
		defer { isUpdatingOutline = false }

		for section in sectionNodes {
			for item in section.itemNodes where matchesDestination(item, destination: destination) {
				let row = outlineView.row(forItem: item)
				if row >= 0 {
					outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
				}
				return
			}
		}
		outlineView.deselectAll(nil)
	}

	private func matchesDestination(_ item: SidebarItemNode, destination: NavigationDestination) -> Bool {
		guard case let .destination(itemDestination) = item.presentation.kind else {
			return false
		}
		return itemDestination == destination
	}
}

extension LibrarySidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
	func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
		if item == nil {
			return sectionNodes.count
		}
		if let section = item as? SidebarSectionNode {
			return section.itemNodes.count
		}
		return 0
	}

	func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
		if item == nil {
			return sectionNodes[index]
		}
		if let section = item as? SidebarSectionNode {
			return section.itemNodes[index]
		}
		return index
	}

	func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
		item is SidebarSectionNode
	}

	func outlineView(_: NSOutlineView, isGroupItem item: Any) -> Bool {
		item is SidebarSectionNode
	}

	func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
		item is SidebarItemNode
	}

	func outlineView(_: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
		item is SidebarSectionNode ? 24 : 26
	}

	func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
		if let section = item as? SidebarSectionNode {
			let reused = outlineView.makeView(withIdentifier: Self.sectionCellIdentifier, owner: nil)
			let cell = (reused as? SidebarSectionCellView) ?? SidebarSectionCellView()
			cell.identifier = Self.sectionCellIdentifier
			cell.configure(title: section.presentation.title)
			return cell
		}
		guard let itemNode = item as? SidebarItemNode else {
			return nil
		}
		let reused = outlineView.makeView(withIdentifier: Self.itemCellIdentifier, owner: nil)
		let cell = (reused as? SidebarItemCellView) ?? SidebarItemCellView()
		cell.identifier = Self.itemCellIdentifier
		cell.configure(with: itemNode.presentation)
		return cell
	}

	func outlineViewSelectionDidChange(_: Notification) {
		guard !isUpdatingOutline else {
			return
		}
		let row = outlineView.selectedRow
		guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItemNode else {
			return
		}
		switch item.presentation.kind {
		case let .destination(destination):
			onSelectDestination(destination)
		case .addFolder:
			applySelection(for: selectedDestination)
			onRequestAddFolder()
		}
	}

	func outlineViewItemDidCollapse(_ notification: Notification) {
		guard !isUpdatingOutline,
		      let section = notification.userInfo?["NSObject"] as? SidebarSectionNode
		else {
			return
		}
		collapsedSectionIds.insert(section.presentation.id)
		if persistsCollapsedState {
			UserDefaults.standard.set(Array(collapsedSectionIds), forKey: Self.collapsedSectionsKey)
		}
	}

	func outlineViewItemDidExpand(_ notification: Notification) {
		guard !isUpdatingOutline,
		      let section = notification.userInfo?["NSObject"] as? SidebarSectionNode
		else {
			return
		}
		collapsedSectionIds.remove(section.presentation.id)
		if persistsCollapsedState {
			UserDefaults.standard.set(Array(collapsedSectionIds), forKey: Self.collapsedSectionsKey)
		}
	}
}
