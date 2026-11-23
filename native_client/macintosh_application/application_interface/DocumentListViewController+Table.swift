import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation
import UniformTypeIdentifiers

/// The table's rows: fixed heights, the cells of headings and documents, dragging, and selection.
extension DocumentListViewController {
	static let headingCellIdentifier = NSUserInterfaceItemIdentifier("headingCell")
	static let documentCellIdentifier = NSUserInterfaceItemIdentifier("documentCell")

	/// A search shows passages; a browsed row under a month's heading leaves the year to the heading.
	func placement(ofRow row: Int) -> DocumentRowPlacement {
		if case .search? = activeRequest {
			return .searching
		}
		if case .period? = model.heading(above: row) {
			return .browsing(underMonth: true)
		}
		return .browsing(underMonth: false)
	}

	func reusableCell<Cell: NSView>(
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

	func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
		model.isHeading(at: row) ? nil : reusableCell(in: tableView, identifier: DocumentListRowView.identifier) {
			DocumentListRowView()
		}
	}

	func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
		row >= 0 && row < model.rowCount && !model.isHeading(at: row)
	}

	func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
		model.isHeading(at: row) ? HeadingRowView.rowHeight : DocumentRowView.rowHeight
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
			cell.configure(
				with: documentRow,
				placement: placement(ofRow: row),
				context: context,
				pictureStore: pictureStore
			)
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
