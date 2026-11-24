import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// Coordinates the sidebar, document list, reader, inspector, and file actions as the four items of
/// one split view, so the toolbar knows every divider. A page, such as a folder or Needs Attention,
/// takes the reader's place while the list and the inspector collapse.
public final class LibraryWorkspaceViewController: NSSplitViewController {
	/// The orders of View > Sort By, in the order of their menu items' tags.
	static let sortOrders: [ListingOrder] = [.documentDate, .addition, .title, .sender]
	/// Applies a change of the navigation, which the window controller owns.
	public typealias NavigationChange = (_ mutate: (inout LibraryNavigationState) -> Void) -> Void

	let queries: any LibraryQueries
	private let renderMode: InterfaceRenderMode
	let wordingContextProvider: () -> ApplicationWordingContext
	private let persistsSplitPositions: Bool
	private let pictureStore: PictureStore
	let actions: WorkspaceDocumentActions
	private let readerContainerController = WindowContainerViewController()
	let pageController: WorkspacePageViewController
	private var listItem: NSSplitViewItem?
	private var inspectorItem: NSSplitViewItem?

	let sidebarController: LibrarySidebarViewController
	let listController: DocumentListViewController
	let readerController: DocumentReaderViewController
	let inspectorController: DocumentInspectorViewController

	private(set) var onNavigationChange: NavigationChange?
	private var onReplaceTokenRequested: (() -> Void)?
	private(set) var onFocusSearchRequested: (() -> Void)?
	private(set) var latestNavigation = LibraryNavigationState()
	private(set) var latestStatuses = ApplicationStatuses()
	private(set) var latestWorkspace: LibraryWorkspacePresentation?
	let detailLoader: SelectedDocumentDetailLoader
	private var showingPage = false
	private var requestedInspectorVisible = true
	private var dividersPlaced = false
	private var hasAppeared = false
	/// The document the reader turned to its text for a search's match, which a person did not choose.
	var textTabChosenForMatch: DocumentIdentifier?

	public init(
		queries: any LibraryQueries,
		collectorCommands: any CollectorCommands,
		renderMode: InterfaceRenderMode = .interactive,
		persistsState: Bool = true,
		wordingContextProvider: @escaping () -> ApplicationWordingContext,
		onNavigationChange: @escaping NavigationChange,
		onReplaceToken: @escaping () -> Void,
		onFocusSearch: @escaping () -> Void
	) {
		self.queries = queries
		self.renderMode = renderMode
		persistsSplitPositions = persistsState
		self.wordingContextProvider = wordingContextProvider
		self.onNavigationChange = onNavigationChange
		onReplaceTokenRequested = onReplaceToken
		onFocusSearchRequested = onFocusSearch

		let store = PictureStore(queries: queries)
		pictureStore = store
		actions = WorkspaceDocumentActions(
			queries: queries,
			collectorCommands: collectorCommands,
			renderMode: renderMode
		)

		weak var target: LibraryWorkspaceViewController?
		sidebarController = Self.makeSidebar(renderMode: renderMode, persistsState: persistsState) { target }
		listController = Self.makeList(queries: queries, store: store, wording: wordingContextProvider) { target }
		readerController = DocumentReaderViewController(
			queries: queries,
			renderMode: renderMode,
			onShowTextForMatch: { target?.showTextForMatch(in: $0) },
			onOpenOriginal: { target?.openSelectedDocumentDefaultApplication(nil) },
			onReplaceToken: { target?.onReplaceTokenRequested?() }
		)
		inspectorController = DocumentInspectorViewController(
			onSelectScope: { target?.navigateToScope($0) },
			onOpenInBrowser: { NSWorkspace.shared.open($0) }
		)
		detailLoader = SelectedDocumentDetailLoader(queries: queries) { document, detail in
			target?.detailLoaded(detail, for: document)
		}
		pageController = WorkspacePageViewController(
			commands: collectorCommands,
			renderMode: renderMode,
			onNavigate: { target?.navigate(to: $0, selecting: $1) },
			onAddFolder: { target?.enrollFolderAction(nil) },
			onReplaceToken: { target?.onReplaceTokenRequested?() }
		)
		super.init(nibName: nil, bundle: nil)
		target = self
		if renderMode == .interactive {
			QuickLookCoordinator.shared.transitionSource = { target?.listController.selectedPicture() }
		}
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override public func viewDidLoad() {
		super.viewDidLoad()
		splitView.dividerStyle = .thin
		if persistsSplitPositions {
			splitView.autosaveName = "org.schublade.libraryWorkspaceSplit"
		}
		// The system's constructors give the toolbar its sections and the glass; offscreen, where the
		// glass draws black, the renderer takes plain items of the same thicknesses.
		let interactive = renderMode == .interactive
		let sidebarItem = interactive
			? NSSplitViewItem(sidebarWithViewController: sidebarController)
			: NSSplitViewItem(viewController: sidebarController)
		// The design's width, which a sidebar must not lose to the window's first, narrower layouts.
		sidebarItem.minimumThickness = 214
		sidebarItem.maximumThickness = 280
		sidebarItem.canCollapse = true
		// The sidebar keeps its width while the list collapses for a page and the window resizes.
		sidebarItem.holdingPriority = NSLayoutConstraint.Priority(280)
		if #available(macOS 26.0, *), Self.statusLineIsAccessory(renderMode: renderMode) {
			let accessory = NSSplitViewItemAccessoryViewController()
			accessory.view = sidebarController.statusBarView
			sidebarItem.addBottomAlignedAccessoryViewController(accessory)
		}

		let listItem = interactive
			? NSSplitViewItem(contentListWithViewController: listController)
			: NSSplitViewItem(viewController: listController)
		listItem.minimumThickness = 270
		listItem.maximumThickness = 440
		listItem.holdingPriority = NSLayoutConstraint.Priority(260)

		let readerItem = NSSplitViewItem(viewController: readerContainerController)
		readerItem.minimumThickness = 360
		readerItem.holdingPriority = NSLayoutConstraint.Priority(240)

		let inspectorItem = interactive
			? NSSplitViewItem(inspectorWithViewController: inspectorController)
			: NSSplitViewItem(viewController: inspectorController)
		inspectorItem.minimumThickness = 220
		inspectorItem.maximumThickness = 320
		inspectorItem.canCollapse = true
		// The inspector gives way first when the window narrows below what the four parts need.
		inspectorItem.canCollapseFromWindowResize = true
		inspectorItem.collapseBehavior = .useConstraints
		inspectorItem.holdingPriority = NSLayoutConstraint.Priority(270)

		for item in [sidebarItem, listItem, readerItem, inspectorItem] {
			addSplitViewItem(item)
		}
		self.listItem = listItem
		self.inspectorItem = inspectorItem
		showingPage = false
		readerContainerController.display(readerController)
		wireKeyViewLoop()
	}

	override public func viewDidAppear() {
		super.viewDidAppear()
		hasAppeared = true
		view.needsLayout = true
	}

	/// The layouts before the window appears are narrower than the window and collapse the
	/// inspector, so the dividers are placed, and the inspector restored, at the first layout after.
	override public func viewDidLayout() {
		super.viewDidLayout()
		guard hasAppeared, !dividersPlaced, splitView.bounds.width > 0, let inspectorItem else {
			return
		}
		dividersPlaced = true
		if requestedInspectorVisible, !showingPage, inspectorItem.isCollapsed {
			inspectorItem.isCollapsed = false
		}
		let sidebarWidth: CGFloat = 214
		let divider = splitView.dividerThickness
		InitialDividerPlacement.place(
			in: splitView,
			at: [sidebarWidth, sidebarWidth + divider + 330, splitView.bounds.width - 250]
		)
	}

	/// Collapses the inspector when the window is about to narrow below what the four parts need.
	/// `canCollapseFromWindowResize` alone left the window at the sum of their minimums, so the
	/// window's minimum of 900 points never held. A frame set from outside arrives already held at
	/// that floor, which the system's sidebar raises a few points above the sum, 1,073 against
	/// 1,067, so a width within 8 points of the sum counts as too narrow.
	public func accommodate(windowWidth width: CGFloat) {
		let shown = splitViewItems.filter { !$0.isCollapsed }
		let needed = shown.reduce(splitView.dividerThickness * CGFloat(shown.count - 1)) { $0 + $1.minimumThickness }
		guard !showingPage, let inspectorItem, !inspectorItem.isCollapsed, width < needed + 8 else {
			return
		}
		requestedInspectorVisible = false
		inspectorItem.isCollapsed = true
		onNavigationChange? { $0.inspectorVisible = false }
	}

	/// Reports a collapse or an expansion of the inspector that the window's width or the system's
	/// toggle made, so the navigation, which the toolbar and the menu read, follows it.
	override public func splitViewDidResizeSubviews(_ notification: Notification) {
		super.splitViewDidResizeSubviews(notification)
		guard dividersPlaced, !showingPage, let inspectorItem else {
			return
		}
		let visible = !inspectorItem.isCollapsed
		if visible != requestedInspectorVisible {
			requestedInspectorVisible = visible
			onNavigationChange? { $0.inspectorVisible = visible }
		}
	}

	public func render(
		workspace: LibraryWorkspacePresentation,
		statuses: ApplicationStatuses,
		navigation: LibraryNavigationState
	) {
		latestWorkspace = workspace
		latestStatuses = statuses
		latestNavigation = navigation
		sidebarController.render(workspace.sidebar, selectedDestination: navigation.destination)

		guard workspace.detailMode == .documents else {
			showPage()
			pageController.render(workspace.detailMode, statuses: statuses, context: wordingContextProvider())
			return
		}
		showDocuments()
		setInspectorVisible(navigation.inspectorVisible, animated: renderMode == .interactive)
		listController.render(navigation: navigation, workspace: workspace, statuses: statuses)
		detailLoader.select(navigation.selectedDocument, revision: statuses.library?.contentRevision ?? 0)
		if navigation.selectedDocument == nil {
			actions.updateQuickLookSelection(nil, detail: nil)
		}
		renderReaderAndInspector(navigation: navigation)
	}

	public func contentRevisionChanged(to revision: UInt64) {
		listController.contentRevisionChanged(to: revision)
		detailLoader.reload(revision: revision)
		readerController.contentRevisionChanged()
	}
}

private extension LibraryWorkspaceViewController {
	static func makeSidebar(
		renderMode: InterfaceRenderMode,
		persistsState: Bool,
		target: @escaping () -> LibraryWorkspaceViewController?
	) -> LibrarySidebarViewController {
		LibrarySidebarViewController(
			renderMode: renderMode,
			persistsCollapsedState: persistsState,
			onSelectDestination: { target()?.selectSidebarDestination($0) },
			onRequestAddFolder: { target()?.enrollFolderAction(nil) },
			pinsStatusLine: !statusLineIsAccessory(renderMode: renderMode),
			onStatusLineAction: { target()?.handleStatusLinePress($0) },
			onShowFolderInFinder: { target()?.showFolderInFinder($0) },
			onRequestFolderRemoval: { target()?.requestRemoval(of: $0) }
		)
	}

	static func makeList(
		queries: any LibraryQueries,
		store: PictureStore,
		wording: @escaping () -> ApplicationWordingContext,
		target: @escaping () -> LibraryWorkspaceViewController?
	) -> DocumentListViewController {
		DocumentListViewController(
			queries: queries,
			pictureStore: store,
			wordingContextProvider: { wording().library },
			onSelectionChanged: { target()?.handleSelectionChanged($0) },
			onOpenSelected: { target()?.openDocument($0) },
			onQuickLookSelected: { target()?.previewDocument($0) },
			onCopySelected: { target()?.copyDocument($0) },
			onDragFailed: { target()?.reportDragFailure($0) },
			onRequestAddFolder: { target()?.enrollFolderAction(nil) },
			onRequestSearchAllDocuments: { target()?.searchAllDocuments() },
			onRowCommand: { target()?.perform($0, on: $1) },
			shareableItems: { row in
				target().map { [$0.actions.shareableItem(for: row.document, suggestedFileName: row.suggestedFileName)] }
					?? []
			}
		)
	}

	/// A page takes the reader's place, and the list and the inspector collapse without animation,
	/// so the dividers keep their places for the return.
	func showPage() {
		guard !showingPage, let listItem else {
			return
		}
		showingPage = true
		readerContainerController.display(pageController)
		listItem.canCollapse = true
		listItem.isCollapsed = true
		inspectorItem?.isCollapsed = true
	}

	func showDocuments() {
		guard showingPage, let listItem else {
			return
		}
		readerContainerController.display(readerController)
		listItem.isCollapsed = false
		listItem.canCollapse = false
		setInspectorVisible(requestedInspectorVisible, animated: false)
		// Only now, so the expansions above do not report the inspector as a person's choice.
		showingPage = false
	}

	func setInspectorVisible(_ visible: Bool, animated: Bool) {
		requestedInspectorVisible = visible
		guard let inspectorItem, inspectorItem.isCollapsed == visible else {
			return
		}
		if animated {
			inspectorItem.animator().isCollapsed = !visible
		} else {
			inspectorItem.isCollapsed = !visible
		}
	}

	func searchAllDocuments() {
		onNavigationChange? { navigation in
			navigation.previousDestination = nil
			navigation.destination = .library(.allDocuments, title: nil)
			navigation.selectedDocument = nil
		}
	}

	func handleStatusLinePress(_ line: StatusLinePresentation) {
		if line.allowsTokenReplacement {
			onReplaceTokenRequested?()
		} else if line.allowsSynchronize {
			queries.synchronize()
		}
	}

	/// A text the reader chose for a match gives way to the original once the search is over.
	func handleSelectionChanged(_ document: DocumentIdentifier?) {
		guard document != latestNavigation.selectedDocument else {
			return
		}
		let returnsToOriginal = textTabChosenForMatch != nil && latestNavigation.searchTerms.isEmpty
		if returnsToOriginal {
			textTabChosenForMatch = nil
		}
		onNavigationChange? { navigation in
			navigation.selectedDocument = document
			if returnsToOriginal {
				navigation.readerTab = .original
			}
		}
	}

	func detailLoaded(_ detail: DocumentDetail, for document: DocumentIdentifier) {
		actions.updateQuickLookSelection(document, detail: detail)
		renderReaderAndInspector(navigation: latestNavigation)
	}

	func renderReaderAndInspector(navigation: LibraryNavigationState) {
		let detail = detailLoader.detail.flatMap { $0.document == navigation.selectedDocument ? $0 : nil }
		let context = wordingContextProvider().library
		readerController.render(
			document: navigation.selectedDocument,
			detail: detail.map { DocumentDetailPresentation.from($0, context: context) },
			tab: navigation.readerTab,
			searchTerms: navigation.searchTerms
		)
		inspectorController.render(detail.map { InspectorPresentation.from($0, context: context) })
		wireKeyViewLoop()
	}

	func copyDocument(_ document: DocumentIdentifier) {
		actions.copyFile(document, suggestedFileName: detailLoader.detail?.suggestedFileName, window: view.window)
	}

	func reportDragFailure(_ refusal: RepresentationRefusal) {
		actions.presentRepresentationAlert(refusal, in: view.window)
	}
}
