import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// Coordinates the sidebar, document list, reader, inspector, and file actions as the four items of
/// one split view, so the toolbar knows every divider. A page, such as a folder or Needs Attention,
/// takes the reader's place while the list and the inspector collapse.
public final class LibraryWorkspaceViewController: NSSplitViewController {
	/// The system's sidebar holds the window a few points above the sum of the parts' minimums, 1,073
	/// against 1,067, so a width within this of the sum counts as too narrow for the inspector.
	private static let heldWidthAllowance: CGFloat = 8
	private static let sidebarHoldingPriority = NSLayoutConstraint.Priority(280)
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
	private var sidebarItem: NSSplitViewItem?
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
	/// The inspector gave way to a window too narrow for it. The person's own choice stays in the
	/// navigation, so the inspector returns once the window holds it again.
	private var inspectorGivenWay = false
	/// The window's width at the last accommodation, so that only a narrowing makes the inspector
	/// give way.
	private var accommodatedWidth = CGFloat.infinity
	private var isApplyingPartsLayout = false
	private var dividersPlaced = false
	private var hasAppeared = false

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
		// Offscreen the glass draws black, so the renderer takes plain items.
		let interactive = renderMode == .interactive
		let sidebarItem = interactive
			? NSSplitViewItem(sidebarWithViewController: sidebarController)
			: NSSplitViewItem(viewController: sidebarController)
		// The design's width, which a sidebar must not lose to the window's first, narrower layouts.
		sidebarItem.minimumThickness = 214
		sidebarItem.maximumThickness = 280
		sidebarItem.canCollapse = true
		sidebarItem.holdingPriority = Self.sidebarHoldingPriority
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
		inspectorItem.collapseBehavior = .useConstraints
		inspectorItem.holdingPriority = NSLayoutConstraint.Priority(270)

		for item in [sidebarItem, listItem, readerItem, inspectorItem] {
			addSplitViewItem(item)
		}
		self.sidebarItem = sidebarItem
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

	/// The layouts before the window appears are narrower than the window, and the split view
	/// restores what it saved, a list collapsed for a page included, so the parts are decided and the
	/// dividers placed at the first layout after.
	override public func viewDidLayout() {
		super.viewDidLayout()
		guard hasAppeared, !dividersPlaced, splitView.bounds.width > 0 else {
			return
		}
		dividersPlaced = true
		accommodatedWidth = .infinity
		accommodate(windowWidth: splitView.bounds.width)
		let sidebarWidth: CGFloat = 214
		let divider = splitView.dividerThickness
		InitialDividerPlacement.place(
			in: splitView,
			at: [sidebarWidth, sidebarWidth + divider + 330, splitView.bounds.width - 250]
		)
	}

	/// Makes the inspector give way when the window narrows below what the four parts need, so the
	/// window's minimum of 900 points holds, and brings it back once the window holds it again. A
	/// window that grows, as it does to hold an inspector a person showed, never takes it away.
	public func accommodate(windowWidth width: CGFloat) {
		if width >= widthHoldingInspector + Self.heldWidthAllowance {
			inspectorGivenWay = false
		} else if width < accommodatedWidth {
			inspectorGivenWay = true
		}
		accommodatedWidth = width
		applyPartsLayout(animated: false)
	}

	/// Shows or hides the inspector as a person asks, and widens a window too narrow for it.
	override public func toggleInspector(_: Any?) {
		guard let inspectorItem else {
			return
		}
		let shows = inspectorItem.isCollapsed
		if shows {
			inspectorGivenWay = false
			widenWindowToHoldInspector()
		}
		onNavigationChange? { $0.inspectorVisible = shows }
	}

	/// A divider dragged to the window's edge, or back from it, is a person's choice too.
	override public func splitViewDidResizeSubviews(_ notification: Notification) {
		super.splitViewDidResizeSubviews(notification)
		guard dividersPlaced, !isApplyingPartsLayout, !showingPage, let inspectorItem else {
			return
		}
		let shown = !inspectorItem.isCollapsed
		if shown != inspectorShown {
			inspectorGivenWay = false
			onNavigationChange? { $0.inspectorVisible = shown }
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
		applyPartsLayout(animated: renderMode == .interactive)
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

extension LibraryWorkspaceViewController {
	/// A page takes the reader's place, and the list and the inspector collapse without animation,
	/// so the dividers keep their places for the return.
	func showPage() {
		guard !showingPage else {
			return
		}
		showingPage = true
		readerContainerController.display(pageController)
		applyPartsLayout(animated: false)
	}

	func showDocuments() {
		guard showingPage else {
			return
		}
		showingPage = false
		readerContainerController.display(readerController)
		applyPartsLayout(animated: false)
	}

	var inspectorShown: Bool {
		!showingPage && latestNavigation.inspectorVisible && !inspectorGivenWay
	}

	/// The narrowest window that holds the list, the reader, the inspector, and the sidebar while it
	/// shows.
	var widthHoldingInspector: CGFloat {
		let parts = splitViewItems.filter { $0 !== sidebarItem || !$0.isCollapsed }
		return parts.reduce(splitView.dividerThickness * CGFloat(parts.count - 1)) { $0 + $1.minimumThickness }
	}

	/// Collapses or expands the list and the inspector to what the page, the person's choice, and the
	/// window's width ask, however often it is called.
	func applyPartsLayout(animated: Bool) {
		guard let listItem, let inspectorItem else {
			return
		}
		isApplyingPartsLayout = true
		defer { isApplyingPartsLayout = false }
		if showingPage {
			listItem.canCollapse = true
		}
		if listItem.isCollapsed != showingPage {
			listItem.isCollapsed = showingPage
		}
		listItem.canCollapse = showingPage
		let inspectorCollapsed = !inspectorShown
		guard inspectorItem.isCollapsed != inspectorCollapsed else {
			return
		}
		if animated {
			inspectorItem.animator().isCollapsed = inspectorCollapsed
		} else {
			inspectorItem.isCollapsed = inspectorCollapsed
		}
	}

	func widenWindowToHoldInspector() {
		guard let window = view.window else {
			return
		}
		var frame = window.frame
		frame.size.width = max(frame.width, widthHoldingInspector + Self.heldWidthAllowance)
		if let visible = window.screen?.visibleFrame {
			frame.size.width = min(frame.width, visible.width)
			frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
		}
		if frame != window.frame {
			window.setFrame(frame, display: true, animate: renderMode == .interactive)
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

	func handleSelectionChanged(_ document: DocumentIdentifier?) {
		guard document != latestNavigation.selectedDocument else {
			return
		}
		onNavigationChange? { $0.selectedDocument = document }
	}

	func detailLoaded(_ detail: DocumentDetail?, for document: DocumentIdentifier) {
		actions.updateQuickLookSelection(document, detail: detail)
		renderReaderAndInspector(navigation: latestNavigation)
	}

	func renderReaderAndInspector(navigation: LibraryNavigationState) {
		let detail = detailLoader.detail.flatMap { $0.document == navigation.selectedDocument ? $0 : nil }
		let context = wordingContextProvider().library
		readerController.render(
			document: navigation.selectedDocument,
			detail: detail.map { DocumentDetailPresentation.from($0, context: context) },
			tab: navigation.shownReaderTab,
			searchTerms: navigation.searchTerms
		)
		// The inspector keeps the previous document's facts until the new detail, or its absence,
		// arrives, so a walk through the list never blanks it.
		if detailLoader.answeredDocument == navigation.selectedDocument {
			inspectorController.render(detail.map { InspectorPresentation.from($0, context: context) })
			wireKeyViewLoop()
		}
	}

	func copyDocument(_ document: DocumentIdentifier) {
		actions.copyFile(document, suggestedFileName: detailLoader.detail?.suggestedFileName, window: view.window)
	}

	func reportDragFailure(_ refusal: RepresentationRefusal) {
		actions.presentRepresentationAlert(refusal, in: view.window)
	}
}
