import AppKit
import ApplicationBindings
import ApplicationPresentation

/// Coordinates the sidebar, document list, reader, inspector, and file actions inside the
/// library workspace split view.
public final class LibraryWorkspaceViewController: NSSplitViewController {
	/// The orders of View > Sort By, in the order of their menu items' tags.
	static let sortOrders: [ListingOrder] = [.documentDate, .addition, .title, .sender]
	/// Applies a change of the navigation, which the window controller owns.
	public typealias NavigationChange = (_ mutate: (inout LibraryNavigationState) -> Void) -> Void

	private let queries: any LibraryQueries
	private let renderMode: InterfaceRenderMode
	let wordingContextProvider: () -> WordingContext
	private let persistsSplitPositions: Bool
	private let pictureStore: PictureStore
	private let actions: WorkspaceDocumentActions
	private let rightContainerController = WindowContainerViewController()
	private let noticeController = WorkspaceNoticeViewController()

	let sidebarController: LibrarySidebarViewController
	let listController: DocumentListViewController
	let readerController: DocumentReaderViewController
	let inspectorController: DocumentInspectorViewController
	let detailSplitController: LibraryDetailSplitViewController

	private var onNavigationChange: NavigationChange?
	private var onReplaceTokenRequested: (() -> Void)?
	private var onFocusSearchRequested: (() -> Void)?
	private var latestNavigation = LibraryNavigationState()
	private var latestStatuses = ApplicationStatuses()
	private var latestWorkspace: LibraryWorkspacePresentation?
	private let detailLoader: SelectedDocumentDetailLoader
	private var showingNoticeScreen = false

	public init(
		queries: any LibraryQueries,
		collectorCommands: any CollectorCommands,
		renderMode: InterfaceRenderMode = .interactive,
		persistsState: Bool = true,
		wordingContextProvider: @escaping () -> WordingContext,
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
			onTabChanged: { target?.setReaderTab($0) },
			onReplaceToken: { target?.onReplaceTokenRequested?() }
		)
		inspectorController = DocumentInspectorViewController(
			onSelectScope: { target?.navigateToScope($0) },
			onOpenInBrowser: { NSWorkspace.shared.open($0) }
		)
		detailSplitController = LibraryDetailSplitViewController(
			listController: listController,
			readerController: readerController,
			inspectorController: inspectorController,
			persistsSplitPositions: persistsState
		)
		detailLoader = SelectedDocumentDetailLoader(queries: queries) { document, detail in
			target?.detailLoaded(detail, for: document)
		}
		super.init(nibName: nil, bundle: nil)
		target = self
		detailSplitController.onToggleSidebar = { [weak self] in self?.toggleWorkspaceSidebar($0) }
		detailSplitController.onInspectorVisibilityChanged = { [weak self] visible in
			self?.onNavigationChange? { $0.inspectorVisible = visible }
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
			splitView.autosaveName = "org.schublade.workspaceSplit"
		}
		let sidebarItem = if renderMode == .interactive {
			NSSplitViewItem(sidebarWithViewController: sidebarController)
		} else {
			NSSplitViewItem(viewController: sidebarController)
		}
		sidebarItem.minimumThickness = 180
		sidebarItem.maximumThickness = 280
		sidebarItem.canCollapse = true
		let detailItem = NSSplitViewItem(viewController: rightContainerController)
		detailItem.minimumThickness = 620
		addSplitViewItem(sidebarItem)
		addSplitViewItem(detailItem)
		splitView.setPosition(214, ofDividerAt: 0)
		showingNoticeScreen = false
		rightContainerController.display(detailSplitController)
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

		switch workspace.detailMode {
		case .documents:
			showDetailSplit()
			detailSplitController.setInspectorVisible(
				navigation.inspectorVisible,
				animated: renderMode == .interactive
			)
			listController.render(navigation: navigation, workspace: workspace, statuses: statuses)
			detailLoader.select(navigation.selectedDocument, revision: statuses.library?.contentRevision ?? 0)
			if navigation.selectedDocument == nil {
				actions.updateQuickLookSelection(nil, detail: nil)
			}
			renderReaderAndInspector(navigation: navigation)
		case let .archiveOutdated(message):
			showNotice(title: "Update Required", detail: message)
		case let .tokenCannotRead(message):
			let title = "Token Cannot Read Archive"
			showNotice(title: title, detail: message, actionTitle: "Replace Token…", onAction: onReplaceTokenRequested)
		case let .needsAttention(summary):
			showNotice(title: "Needs Attention", detail: summary)
		case let .folder(_, name):
			showNotice(title: name, detail: "Folder controls arrive in the next update.")
		}
	}

	public func contentRevisionChanged(to revision: UInt64) {
		listController.contentRevisionChanged(to: revision)
		detailLoader.reload(revision: revision)
		readerController.contentRevisionChanged()
	}
}

extension LibraryWorkspaceViewController: NSMenuItemValidation {
	public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		let hasSelection = latestNavigation.selectedDocument != nil
		let allowsDocuments = latestWorkspace?.detailMode == .documents
		switch menuItem.action {
		case #selector(openSelectedDocumentDefaultApplication(_:)),
		     #selector(toggleQuickLookAction(_:)),
		     #selector(exportSelectedDocument(_:)):
			return allowsDocuments && hasSelection
		case #selector(openSelectedDocumentInBrowser(_:)):
			return allowsDocuments && detailLoader.detail.flatMap { URL(string: $0.archivePage) } != nil
		case #selector(toggleDocumentInspector(_:)):
			return allowsDocuments
		case #selector(selectSortOrder(_:)):
			if let effective = latestWorkspace?.effectiveOrder {
				menuItem.state = Self.sortOrders.firstIndex(of: effective) == menuItem.tag ? .on : .off
			}
			return latestWorkspace?.allowsSortSelection ?? false
		case #selector(enrollFolderAction(_:)):
			return latestStatuses.collector != nil
		default:
			return true
		}
	}
}

extension LibraryWorkspaceViewController {
	func wireKeyViewLoop() {
		sidebarController.focusTargetView.nextKeyView = listController.focusTargetView
		listController.focusTargetView.nextKeyView = readerController.focusTargetView
	}

	func shareSelectedDocument(anchoredTo anchorView: NSView) {
		guard let document = latestNavigation.selectedDocument else {
			return
		}
		actions.share(document, anchoredTo: anchorView, window: view.window)
	}

	@objc func toggleWorkspaceSidebar(_ sender: Any?) {
		super.toggleSidebar(sender)
	}

	@objc func focusSearchFieldAction(_: Any?) {
		onFocusSearchRequested?()
	}

	@objc func showOriginalRepresentation(_: Any?) {
		setReaderTab(.original)
	}

	@objc func showExtractedTextRepresentation(_: Any?) {
		setReaderTab(.text)
	}

	@objc func toggleDocumentInspector(_: Any?) {
		onNavigationChange? { $0.inspectorVisible.toggle() }
	}

	@objc func synchronizeLibrary(_: Any?) {
		queries.synchronize()
	}

	@objc func openSelectedDocumentInBrowser(_: Any?) {
		guard let urlText = detailLoader.detail?.archivePage, let url = URL(string: urlText) else {
			return
		}
		NSWorkspace.shared.open(url)
	}

	@objc func exportSelectedDocument(_: Any?) {
		guard let document = latestNavigation.selectedDocument else {
			return
		}
		actions.export(document, suggestedFileName: detailLoader.detail?.suggestedFileName, window: view.window)
	}

	@objc func enrollFolderAction(_: Any?) {
		actions.presentAddFolderPanel(in: view.window) { [weak self] folder in
			self?.onNavigationChange? { $0.destination = .folder(folder.identifier) }
		}
	}

	@objc func openSelectedDocumentDefaultApplication(_: Any?) {
		latestNavigation.selectedDocument.map(openDocument)
	}

	@objc func toggleQuickLookAction(_: Any?) {
		latestNavigation.selectedDocument.map(previewDocument)
	}

	@objc func selectSortOrder(_ sender: NSMenuItem) {
		guard Self.sortOrders.indices.contains(sender.tag) else {
			return
		}
		let selected = Self.sortOrders[sender.tag]
		onNavigationChange? { $0.browseOrder = selected }
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
			onStatusLineAction: { target()?.handleStatusLinePress($0) }
		)
	}

	static func makeList(
		queries: any LibraryQueries,
		store: PictureStore,
		wording: @escaping () -> WordingContext,
		target: @escaping () -> LibraryWorkspaceViewController?
	) -> DocumentListViewController {
		DocumentListViewController(
			queries: queries,
			pictureStore: store,
			wordingContextProvider: wording,
			onSelectionChanged: { target()?.handleSelectionChanged($0) },
			onOpenSelected: { target()?.openDocument($0) },
			onQuickLookSelected: { target()?.previewDocument($0) },
			onCopySelected: { target()?.copyDocument($0) },
			onDragFailed: { target()?.reportDragFailure($0) },
			onRequestAddFolder: { target()?.enrollFolderAction(nil) },
			onRequestSearchAllDocuments: { target()?.searchAllDocuments() }
		)
	}

	func showDetailSplit() {
		guard showingNoticeScreen else {
			return
		}
		showingNoticeScreen = false
		rightContainerController.display(detailSplitController)
	}

	func showNotice(title: String, detail: String, actionTitle: String? = nil, onAction: (() -> Void)? = nil) {
		if !showingNoticeScreen {
			showingNoticeScreen = true
			rightContainerController.display(noticeController)
		}
		noticeController.render(title: title, detail: detail, actionTitle: actionTitle, onAction: onAction)
	}

	func selectSidebarDestination(_ destination: NavigationDestination) {
		onNavigationChange? { navigation in
			navigation.previousDestination = nil
			navigation.destination = destination
			navigation.selectedDocument = nil
		}
	}

	func navigateToScope(_ scope: NamedScope) {
		onNavigationChange? { navigation in
			navigation.previousDestination = if case .sender = scope.scope {
				navigation.destination
			} else {
				nil
			}
			navigation.destination = .library(scope.scope, title: scope.name)
			navigation.selectedDocument = nil
		}
	}

	func searchAllDocuments() {
		onNavigationChange? { navigation in
			navigation.previousDestination = nil
			navigation.destination = .library(.allDocuments, title: nil)
			navigation.selectedDocument = nil
		}
	}

	func setReaderTab(_ tab: ReaderTab) {
		onNavigationChange? { $0.readerTab = tab }
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

	func detailLoaded(_ detail: DocumentDetail, for document: DocumentIdentifier) {
		actions.updateQuickLookSelection(document, detail: detail)
		renderReaderAndInspector(navigation: latestNavigation)
	}

	func renderReaderAndInspector(navigation: LibraryNavigationState) {
		let presented = if let detail = detailLoader.detail, detail.document == navigation.selectedDocument {
			DocumentDetailPresentation.from(detail, context: wordingContextProvider())
		} else {
			DocumentDetailPresentation?.none
		}
		readerController.render(
			document: navigation.selectedDocument,
			detail: presented,
			tab: navigation.readerTab,
			searchTerms: navigation.searchTerms
		)
		inspectorController.render(presented, hasSelection: navigation.selectedDocument != nil)
	}

	func openDocument(_ document: DocumentIdentifier) {
		actions.openInDefaultApplication(document, window: view.window)
	}

	func previewDocument(_ document: DocumentIdentifier) {
		actions.toggleQuickLook(for: document, title: detailLoader.detail?.title, window: view.window)
	}

	func copyDocument(_ document: DocumentIdentifier) {
		actions.copyFile(document, window: view.window)
	}

	func reportDragFailure(_ refusal: RepresentationRefusal) {
		actions.presentRepresentationAlert(refusal, in: view.window)
	}
}
