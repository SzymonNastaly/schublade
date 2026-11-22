import AppKit
import ApplicationBindings

/// Displays the library's documents in a fixed-height table backed by `DocumentListModel`.
final class DocumentListViewController: NSViewController {
	private static let headingCellIdentifier = NSUserInterfaceItemIdentifier("headingCell")
	private static let documentCellIdentifier = NSUserInterfaceItemIdentifier("documentCell")

	private let queries: any LibraryQueries
	private let model = DocumentListModel()
	private var request = ListingRequest.browse(scope: .allDocuments, order: .documentDate)
	private var newestRequestNumber: UInt64 = 0
	private var libraryStatus: LibraryStatus?
	private var listingFaultText: String?

	private let headerBar = NSView()
	private let summaryLabel = NSTextField(labelWithString: "")
	private let refreshButton = NSButton()
	private let separator = NSBox()
	private let tableView = NSTableView()
	private let scrollView = NSScrollView()
	private let emptyLabel = NSTextField(wrappingLabelWithString: "")

	init(queries: any LibraryQueries) {
		self.queries = queries
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		configureHeaderBar()
		configureTableView()
		configureLayout()
		updateChrome()
		refresh()
	}

	func render(libraryStatus: LibraryStatus) {
		self.libraryStatus = libraryStatus
		updateChrome()
	}

	func contentRevisionChanged(to _: UInt64) {
		refresh()
	}

	private func configureHeaderBar() {
		summaryLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
		summaryLabel.lineBreakMode = .byTruncatingTail
		summaryLabel.translatesAutoresizingMaskIntoConstraints = false
		summaryLabel.setAccessibilityIdentifier(InterfaceIdentifier.documentListSummaryLabel)

		refreshButton.title = "Refresh"
		refreshButton.bezelStyle = .rounded
		refreshButton.target = self
		refreshButton.action = #selector(synchronizeArchive)
		refreshButton.translatesAutoresizingMaskIntoConstraints = false
		refreshButton.setAccessibilityIdentifier(InterfaceIdentifier.documentListRefreshButton)

		headerBar.translatesAutoresizingMaskIntoConstraints = false
		headerBar.addSubview(summaryLabel)
		headerBar.addSubview(refreshButton)

		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false
	}

	private func configureTableView() {
		let documentColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("documentColumn"))
		documentColumn.resizingMask = .autoresizingMask
		tableView.addTableColumn(documentColumn)
		tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
		tableView.headerView = nil
		tableView.usesAutomaticRowHeights = false
		tableView.floatsGroupRows = true
		tableView.rowSizeStyle = .custom
		tableView.intercellSpacing = NSSize(width: 0, height: 0)
		tableView.dataSource = self
		tableView.delegate = self
		tableView.setAccessibilityIdentifier(InterfaceIdentifier.documentListTable)

		scrollView.documentView = tableView
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = true
		scrollView.translatesAutoresizingMaskIntoConstraints = false

		emptyLabel.alignment = .center
		emptyLabel.textColor = .secondaryLabelColor
		emptyLabel.isHidden = true
		emptyLabel.translatesAutoresizingMaskIntoConstraints = false
		emptyLabel.setAccessibilityIdentifier(InterfaceIdentifier.documentListEmptyLabel)
	}

	private func configureLayout() {
		view.addSubview(headerBar)
		view.addSubview(separator)
		view.addSubview(scrollView)
		view.addSubview(emptyLabel)

		NSLayoutConstraint.activate([
			headerBar.topAnchor.constraint(equalTo: view.topAnchor),
			headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			headerBar.heightAnchor.constraint(equalToConstant: 44),
			summaryLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 16),
			summaryLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
			summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -12),
			refreshButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -16),
			refreshButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
			separator.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
			separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
			emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
			emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 32),
			emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -32),
		])
	}

	@objc private func synchronizeArchive() {
		queries.synchronize()
	}

	private func refresh() {
		newestRequestNumber &+= 1
		let requestNumber = newestRequestNumber
		let activeRequest = request
		let preceding = model.listing
		let previousRowCount = model.rowCount

		Task {
			await loadListing(
				requestNumber: requestNumber,
				activeRequest: activeRequest,
				preceding: preceding,
				previousRowCount: previousRowCount
			)
		}
	}

	private func loadListing(
		requestNumber: UInt64,
		activeRequest: ListingRequest,
		preceding: DocumentListing?,
		previousRowCount: Int
	) async {
		do {
			let answer = try await queries.listDocuments(request: activeRequest, preceding: preceding)
			guard requestNumber == newestRequestNumber else {
				return
			}
			listingFaultText = nil
			let update = model.adopt(answer, preceding: preceding)
			apply(update, previousRowCount: previousRowCount)
			updateChrome()
		} catch {
			guard requestNumber == newestRequestNumber else {
				return
			}
			switch error {
			case .Stopped:
				break
			case let .StoreFailed(detail):
				listingFaultText = "Could not read documents: \(detail)"
				updateChrome()
			case let .Unexpected(detail):
				listingFaultText = "Could not read documents: \(detail)"
				updateChrome()
			}
		}
	}

	private func apply(_ update: DocumentListUpdate, previousRowCount: Int) {
		if tableView.numberOfRows != previousRowCount {
			tableView.reloadData()
			return
		}
		switch update {
		case .reload:
			tableView.reloadData()
		case let .difference(removed, inserted, revised):
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
	}

	private func updateChrome() {
		summaryLabel.stringValue = DocumentListModel.summarySentence(
			documentCount: model.documentCount,
			status: libraryStatus
		)

		if let listingFaultText {
			emptyLabel.stringValue = listingFaultText
			emptyLabel.isHidden = false
			return
		}
		if model.rowCount > 0 {
			emptyLabel.isHidden = true
			return
		}
		if case let .filling(received, remaining) = libraryStatus?.copy {
			emptyLabel.stringValue = "Loading documents (\(received) received, \(remaining) remaining)…"
		} else {
			emptyLabel.stringValue = "No Documents Yet"
		}
		emptyLabel.isHidden = false
	}

	private func reusableHeadingCell(in tableView: NSTableView) -> HeadingRowView {
		let rawView = tableView.makeView(withIdentifier: Self.headingCellIdentifier, owner: nil)
		if let existing = rawView as? HeadingRowView {
			return existing
		}
		let cell = HeadingRowView()
		cell.identifier = Self.headingCellIdentifier
		return cell
	}

	private func reusableDocumentCell(in tableView: NSTableView) -> DocumentRowView {
		let rawView = tableView.makeView(withIdentifier: Self.documentCellIdentifier, owner: nil)
		if let existing = rawView as? DocumentRowView {
			return existing
		}
		let cell = DocumentRowView()
		cell.identifier = Self.documentCellIdentifier
		return cell
	}
}

extension DocumentListViewController: NSTableViewDataSource, NSTableViewDelegate {
	func numberOfRows(in _: NSTableView) -> Int {
		model.rowCount
	}

	func tableView(_: NSTableView, isGroupRow row: Int) -> Bool {
		guard let entry = model.row(at: row) else { return false }
		if case .heading = entry {
			return true
		}
		return false
	}

	func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
		guard let entry = model.row(at: row) else { return false }
		if case .document = entry {
			return true
		}
		return false
	}

	func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
		guard let entry = model.row(at: row) else { return 68 }
		switch entry {
		case .heading: return 26
		case .document: return 68
		}
	}

	func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
		guard let entry = model.row(at: row) else { return nil }
		switch entry {
		case let .heading(heading):
			let cell = reusableHeadingCell(in: tableView)
			cell.configure(title: DocumentListModel.headingText(heading))
			return cell
		case let .document(documentRow):
			let cell = reusableDocumentCell(in: tableView)
			cell.configure(with: documentRow)
			return cell
		}
	}
}
