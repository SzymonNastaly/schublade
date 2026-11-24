import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// Middle library pane: displays fixed-height headings and document rows with thumbnails, empty
/// states, search footer, a context menu, drag-out file promises, and keyboard navigation.
final class DocumentListViewController: NSViewController {
	let queries: any LibraryQueries
	let pictureStore: PictureStore
	let wordingContextProvider: () -> WordingContext
	let onSelectionChanged: (DocumentIdentifier?) -> Void
	private let onOpenSelected: (DocumentIdentifier) -> Void
	private let onQuickLookSelected: (DocumentIdentifier) -> Void
	private let onCopySelected: (DocumentIdentifier) -> Void
	let onDragFailed: (RepresentationRefusal) -> Void
	private let onRequestAddFolder: () -> Void
	private let onRequestSearchAllDocuments: () -> Void
	let onRowCommand: (DocumentRowCommand, DocumentRow) -> Void
	let shareableItems: (DocumentRow) -> [Any]
	var onShownDocumentsChanged: ((Int) -> Void)?

	let model = DocumentListModel()
	private(set) var activeRequest: ListingRequest?
	private var activeNavigation = LibraryNavigationState()
	private var libraryStatus: LibraryStatus?
	private var libraryFault: ApplicationFault?
	private var listingFaultText: String?
	private var hasCollector = true
	private var searchAllDocumentsAvailable = false
	private var textIndexingNotice: String?
	private var newestRequestNumber: UInt64 = 0
	private(set) var isApplyingTableUpdates = false
	private var pendingScroll = PendingScroll.selection
	private(set) var incrementalUpdateCount = 0

	let tableView = DocumentListTableView()
	private let scrollView = NSScrollView()
	private lazy var emptyView = EmptyStateView { [weak self] action in
		switch action {
		case .addFolder: self?.onRequestAddFolder()
		case .searchAllDocuments: self?.onRequestSearchAllDocuments()
		case .replaceToken, .tryAgain: break
		}
	}

	private let contextMenu = NSMenu()
	private let footerView = DocumentListFooterView()

	var focusTargetView: NSView {
		tableView
	}

	init(
		queries: any LibraryQueries,
		pictureStore: PictureStore,
		wordingContextProvider: @escaping () -> WordingContext,
		onSelectionChanged: @escaping (DocumentIdentifier?) -> Void,
		onOpenSelected: @escaping (DocumentIdentifier) -> Void,
		onQuickLookSelected: @escaping (DocumentIdentifier) -> Void,
		onCopySelected: @escaping (DocumentIdentifier) -> Void,
		onDragFailed: @escaping (RepresentationRefusal) -> Void,
		onRequestAddFolder: @escaping () -> Void,
		onRequestSearchAllDocuments: @escaping () -> Void,
		onRowCommand: @escaping (DocumentRowCommand, DocumentRow) -> Void,
		shareableItems: @escaping (DocumentRow) -> [Any]
	) {
		self.queries = queries
		self.pictureStore = pictureStore
		self.wordingContextProvider = wordingContextProvider
		self.onSelectionChanged = onSelectionChanged
		self.onOpenSelected = onOpenSelected
		self.onQuickLookSelected = onQuickLookSelected
		self.onCopySelected = onCopySelected
		self.onDragFailed = onDragFailed
		self.onRequestAddFolder = onRequestAddFolder
		self.onRequestSearchAllDocuments = onRequestSearchAllDocuments
		self.onRowCommand = onRowCommand
		self.shareableItems = shareableItems
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 600))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		configureTableView()
		configureLayout()
		updateEmptyAndFooterViews()
	}

	func render(
		navigation: LibraryNavigationState,
		workspace: LibraryWorkspacePresentation,
		statuses: ApplicationStatuses
	) {
		let nextRequest = navigation.activeListingRequest
		let requestChanged = nextRequest != activeRequest
		let previousSelection = activeNavigation.selectedDocument
		activeNavigation = navigation
		libraryStatus = statuses.library
		libraryFault = statuses.libraryFault
		hasCollector = statuses.collector != nil
		searchAllDocumentsAvailable = workspace.searchAllDocumentsAvailable
		textIndexingNotice = workspace.textIndexingNotice
		if requestChanged {
			pendingScroll = PendingScroll.after(activeRequest, changedTo: nextRequest)
			activeRequest = nextRequest
			if nextRequest == nil {
				newestRequestNumber &+= 1
			} else {
				refresh()
			}
		} else if previousSelection != navigation.selectedDocument {
			pendingScroll = navigation.selectedDocument != selectedDocumentIdentifier() ? .selection : .unchanged
			restoreSelection(to: navigation.selectedDocument, notifyIfMissing: false)
		}
		updateEmptyAndFooterViews()
	}

	func contentRevisionChanged(to revision: UInt64) {
		pictureStore.contentRevisionChanged(to: revision)
		if activeRequest != nil {
			refresh()
		}
	}

	var shownDocuments: Int? {
		model.listing == nil ? nil : model.documentCount
	}

	func selectedDocumentIdentifier() -> DocumentIdentifier? {
		tableView.selectedRow >= 0 ? model.documentIdentifier(at: tableView.selectedRow) : nil
	}

	/// Selects the first document while nothing is selected, as a search's Down or Return does.
	func selectFirstDocumentIfNoneSelected() {
		guard tableView.selectedRow < 0,
		      let first = (0 ..< model.rowCount).first(where: { model.documentIdentifier(at: $0) != nil })
		else {
			return
		}
		tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
		tableView.scrollRowToVisible(first)
	}

	@objc func copy(_: Any?) {
		selectedDocumentIdentifier().map(onCopySelected)
	}

	/// The selected document's picture and its frame on screen, which Quick Look grows out of.
	func selectedPicture() -> (frame: NSRect, picture: NSImage?)? {
		let row = tableView.selectedRow
		guard row >= 0, tableView.rows(in: tableView.visibleRect).contains(row),
		      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? DocumentRowView,
		      let window = view.window
		else {
			return nil
		}
		return (window.convertToScreen(cell.pictureFrameInWindow), cell.shownPicture)
	}
}

private extension DocumentListViewController {
	func configureTableView() {
		let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("documentColumn"))
		column.resizingMask = .autoresizingMask
		tableView.addTableColumn(column)
		tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
		tableView.headerView = nil
		tableView.usesAutomaticRowHeights = false
		tableView.floatsGroupRows = true
		tableView.rowSizeStyle = .custom
		tableView.intercellSpacing = NSSize(width: 0, height: 0)
		tableView.allowsEmptySelection = true
		tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
		tableView.target = self
		tableView.doubleAction = #selector(tableDoubleClicked)
		tableView.dataSource = self
		tableView.delegate = self
		tableView.setAccessibilityIdentifier(InterfaceIdentifier.documentListTable)
		contextMenu.delegate = self
		tableView.menu = contextMenu
		tableView.onQuickLook = { [weak self] in
			self.map { $0.selectedDocumentIdentifier().map($0.onQuickLookSelected) }
		}
		tableView.onOpenSelectedDocument = { [weak self] in
			self.map { $0.selectedDocumentIdentifier().map($0.onOpenSelected) }
		}
		scrollView.documentView = tableView
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = true
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		emptyView.isHidden = true
		emptyView.translatesAutoresizingMaskIntoConstraints = false
		footerView.isHidden = true
		footerView.translatesAutoresizingMaskIntoConstraints = false
	}

	func configureLayout() {
		let stack = NSStackView(views: [scrollView, footerView])
		stack.orientation = .vertical
		stack.spacing = 0
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)
		view.addSubview(emptyView)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: view.topAnchor),
			stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
			footerView.widthAnchor.constraint(equalTo: stack.widthAnchor),
			emptyView.topAnchor.constraint(equalTo: scrollView.topAnchor),
			emptyView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
			emptyView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
			emptyView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
		])
	}

	func refresh() {
		guard let request = activeRequest else {
			return
		}
		newestRequestNumber &+= 1
		let requestNumber = newestRequestNumber
		let preceding = model.listing
		let previousRowCount = model.rowCount
		Task {
			await loadListing(
				requestNumber: requestNumber,
				request: request,
				preceding: preceding,
				previousRowCount: previousRowCount
			)
		}
	}

	func loadListing(
		requestNumber: UInt64,
		request: ListingRequest,
		preceding: (any DocumentListingSnapshot)?,
		previousRowCount: Int
	) async {
		do {
			let reply = try await queries.listDocuments(request: request, preceding: preceding)
			guard requestNumber == newestRequestNumber else {
				return
			}
			listingFaultText = nil
			let selectedBefore = activeNavigation.selectedDocument
			let update = model.adopt(reply, preceding: preceding)
			apply(update, previousRowCount: previousRowCount, preservedSelection: selectedBefore)
			updateEmptyAndFooterViews()
		} catch {
			guard requestNumber == newestRequestNumber else {
				return
			}
			if case .Stopped = error {
				return
			}
			listingFaultText = LibraryFailureWording.faultSentence(error)
			updateEmptyAndFooterViews()
		}
	}

	@objc func tableDoubleClicked() {
		guard tableView.clickedRow >= 0, let document = model.documentIdentifier(at: tableView.clickedRow) else {
			return
		}
		onOpenSelected(document)
	}

	func apply(_ update: DocumentListModel.Update, previousRowCount: Int, preservedSelection: DocumentIdentifier?) {
		onShownDocumentsChanged?(model.documentCount)
		isApplyingTableUpdates = true
		if tableView.numberOfRows != previousRowCount {
			tableView.reloadData()
		} else {
			switch update {
			case .reload:
				tableView.reloadData()
			case let .difference(removed, inserted, revised):
				if !removed.isEmpty || !inserted.isEmpty || !revised.isEmpty {
					incrementalUpdateCount += 1
				}
				applyIncrementalChanges(removed: removed, inserted: inserted, revised: revised)
			}
		}
		isApplyingTableUpdates = false
		if pendingScroll == .top {
			pendingScroll = .unchanged
			if model.rowCount > 0 {
				tableView.scrollRowToVisible(0)
			}
		}
		restoreSelection(to: preservedSelection, notifyIfMissing: true)
	}

	/// A revised row, such as a document that finished its ingestion, dissolves into its new state.
	func applyIncrementalChanges(removed: IndexSet, inserted: IndexSet, revised: IndexSet) {
		if !removed.isEmpty || !inserted.isEmpty {
			tableView.beginUpdates()
			if !removed.isEmpty {
				tableView.removeRows(at: removed, withAnimation: .effectFade)
			}
			if !inserted.isEmpty {
				tableView.insertRows(at: inserted, withAnimation: .effectFade)
			}
			tableView.endUpdates()
		}
		if !revised.isEmpty {
			let dissolve = CATransition()
			dissolve.type = .fade
			dissolve.duration = 0.25
			for row in revised {
				tableView.rowView(atRow: row, makeIfNecessary: false)?.layer?.add(dissolve, forKey: "revision")
			}
			tableView.reloadData(forRowIndexes: revised, columnIndexes: IndexSet(integer: 0))
		}
	}

	func restoreSelection(to document: DocumentIdentifier?, notifyIfMissing: Bool) {
		isApplyingTableUpdates = true
		defer { isApplyingTableUpdates = false }
		if let document, let position = model.position(of: document), position >= 0, position < model.rowCount {
			if tableView.selectedRow != position {
				tableView.selectRowIndexes(IndexSet(integer: position), byExtendingSelection: false)
			}
			if pendingScroll == .selection {
				pendingScroll = .unchanged
				tableView.scrollRowToVisible(position)
			}
			return
		}
		tableView.deselectAll(nil)
		if notifyIfMissing, document != nil {
			onSelectionChanged(nil)
		}
	}

	func updateEmptyAndFooterViews() {
		if model.rowCount > 0 {
			emptyView.isHidden = true
		} else {
			emptyView.render(EmptyStatePresentation.list(
				navigation: activeNavigation,
				libraryStatus: libraryStatus,
				libraryFault: libraryFault,
				listingFault: listingFaultText,
				hasCollector: hasCollector
			))
			emptyView.isHidden = false
		}
		footerView.render(
			// An empty list offers the same button in its middle.
			showsSearchAllDocuments: searchAllDocumentsAvailable && model.rowCount > 0,
			indexingNotice: textIndexingNotice,
			onSearchAllDocuments: onRequestSearchAllDocuments
		)
	}
}

/// Where the list scrolls once its next listing arrives.
private enum PendingScroll {
	case unchanged
	/// To the selected document, which came from outside the list: a launch, the menu bar, or a sort.
	case selection
	/// To the first result of a new search or scope, above any document still selected.
	case top

	static func after(_ previous: ListingRequest?, changedTo next: ListingRequest?) -> PendingScroll {
		switch (previous, next) {
		case (nil, _):
			.selection
		case let (.browse(previousScope, _)?, .browse(nextScope, _)?) where previousScope == nextScope:
			.selection
		default:
			.top
		}
	}
}
