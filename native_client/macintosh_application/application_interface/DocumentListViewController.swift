import AppKit
import ApplicationBindings
import ApplicationPresentation
import UniformTypeIdentifiers

/// Middle library pane: displays fixed-height headings and document rows with thumbnails, empty
/// states, search footer, drag-out file promises, and keyboard navigation.
final class DocumentListViewController: NSViewController {
	private static let headingCellIdentifier = NSUserInterfaceItemIdentifier("headingCell")
	private static let documentCellIdentifier = NSUserInterfaceItemIdentifier("documentCell")

	private let queries: any LibraryQueries
	private let pictureStore: PictureStore
	private let wordingContextProvider: () -> WordingContext
	private let onSelectionChanged: (DocumentIdentifier?) -> Void
	private let onOpenSelected: (DocumentIdentifier) -> Void
	private let onQuickLookSelected: (DocumentIdentifier) -> Void
	private let onCopySelected: (DocumentIdentifier) -> Void
	private let onDragFailed: (RepresentationRefusal) -> Void
	private let onRequestAddFolder: () -> Void
	private let onRequestSearchAllDocuments: () -> Void
	/// Called with the number of documents the list shows after each listing it applies.
	var onShownDocumentsChanged: ((Int) -> Void)?

	private let model = DocumentListModel()
	private var activeRequest: ListingRequest?
	private var activeNavigation = LibraryNavigationState()
	private var libraryStatus: LibraryStatus?
	private var libraryFault: ApplicationFault?
	private var listingFaultText: String?
	private var hasCollector = true
	private var searchAllDocumentsAvailable = false
	private var textIndexingNotice: String?
	private var newestRequestNumber: UInt64 = 0
	private var isApplyingTableUpdates = false
	private(set) var incrementalUpdateCount = 0

	private let tableView = DocumentListTableView()
	private let scrollView = NSScrollView()
	private let emptyView = DocumentListEmptyView()
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
		onRequestSearchAllDocuments: @escaping () -> Void
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
			activeRequest = nextRequest
			if nextRequest == nil {
				newestRequestNumber &+= 1
			} else {
				refresh()
			}
		} else if previousSelection != navigation.selectedDocument {
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

	@objc func copy(_: Any?) {
		selectedDocumentIdentifier().map(onCopySelected)
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
		tableView.onQuickLook = { [weak self] in
			guard let self, let document = selectedDocumentIdentifier() else {
				return
			}
			onQuickLookSelected(document)
		}
		tableView.onOpenSelectedDocument = { [weak self] in
			guard let self, let document = selectedDocumentIdentifier() else {
				return
			}
			onOpenSelected(document)
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
			listingFaultText = ApplicationFailureWording.faultSentence(error)
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
		restoreSelection(to: preservedSelection, notifyIfMissing: true)
	}

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
			let presentation = EmptyListPresentation.resolve(
				navigation: activeNavigation,
				libraryStatus: libraryStatus,
				libraryFault: libraryFault,
				listingFault: listingFaultText,
				hasCollector: hasCollector
			)
			emptyView.render(
				presentation,
				onAddFolder: onRequestAddFolder,
				onSearchAllDocuments: onRequestSearchAllDocuments
			)
			emptyView.isHidden = false
		}
		footerView.render(
			showsSearchAllDocuments: searchAllDocumentsAvailable,
			indexingNotice: textIndexingNotice,
			onSearchAllDocuments: onRequestSearchAllDocuments
		)
	}

	func reusableCell<Cell: NSTableCellView>(
		in tableView: NSTableView,
		identifier: NSUserInterfaceItemIdentifier,
		makeCell: () -> Cell
	) -> Cell {
		if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell {
			return existing
		}
		let created = makeCell()
		created.identifier = identifier
		return created
	}
}

extension DocumentListViewController: NSTableViewDataSource, NSTableViewDelegate {
	func numberOfRows(in _: NSTableView) -> Int {
		model.rowCount
	}

	func tableView(_: NSTableView, isGroupRow row: Int) -> Bool {
		model.isHeading(at: row)
	}

	func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
		row >= 0 && row < model.rowCount && !model.isHeading(at: row)
	}

	func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
		model.isHeading(at: row) ? 26 : 68
	}

	func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
		guard let entry = model.row(at: row) else {
			return nil
		}
		let context = wordingContextProvider()
		switch entry {
		case let .heading(heading):
			let cell = reusableCell(in: tableView, identifier: Self.headingCellIdentifier) { HeadingRowView() }
			cell.configure(title: DocumentFormatting.headingText(heading, context: context))
			return cell
		case let .document(documentRow):
			let cell = reusableCell(in: tableView, identifier: Self.documentCellIdentifier) { DocumentRowView() }
			cell.configure(with: documentRow, context: context, pictureStore: pictureStore)
			return cell
		}
	}

	func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
		guard case let .document(documentRow) = model.row(at: row) else {
			return nil
		}
		let delegate = DocumentFilePromiseDelegate(
			document: documentRow.document,
			fileName: documentRow.suggestedFileName,
			fetchOriginalPath: { [queries] identifier throws(RepresentationRefusal) in
				try await queries.original(identifier).path
			},
			reportFailure: { [onDragFailed] refusal in onDragFailed(refusal) }
		)
		let provider = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: delegate)
		// The provider holds its delegate weakly, so the delegate rides along as its user info.
		provider.userInfo = delegate
		return provider
	}

	func tableViewSelectionDidChange(_: Notification) {
		if !isApplyingTableUpdates {
			onSelectionChanged(selectedDocumentIdentifier())
		}
	}
}
