import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// The commands of the main menu and the toolbar that act on the workspace, and which of them apply.
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
		case #selector(toggleInspector(_:)):
			return allowsDocuments && super.validateUserInterfaceItem(menuItem)
		case #selector(toggleSidebar(_:)):
			// The split view switches the title between Show Sidebar and Hide Sidebar.
			return super.validateUserInterfaceItem(menuItem)
		case #selector(showOriginalRepresentation(_:)):
			menuItem.state = latestNavigation.shownReaderTab == .original ? .on : .off
			return allowsDocuments && hasSelection
		case #selector(showExtractedTextRepresentation(_:)):
			menuItem.state = latestNavigation.shownReaderTab == .text ? .on : .off
			return allowsDocuments && hasSelection
		case #selector(removeShownFolderAction(_:)):
			guard case .folder? = latestWorkspace?.detailMode else {
				return false
			}
			return true
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
	/// Tab runs from the sidebar to the list, the reader, and the inspector's controls, and back to the
	/// sidebar. A hidden pane or a collapsed inspector cannot take the keyboard, so Tab passes over it.
	func wireKeyViewLoop() {
		let loop = [sidebarController.focusTargetView, listController.focusTargetView]
			+ readerController.keyViews
			+ inspectorController.keyViews
		for (view, next) in zip(loop, loop.dropFirst() + loop.prefix(1)) {
			view.nextKeyView = next
		}
	}

	/// Gives the list the keyboard, and with `selectingFirstDocument` selects the first result while
	/// nothing is selected.
	func moveFocusToList(selectingFirstDocument: Bool) {
		guard latestWorkspace?.detailMode == .documents else {
			return
		}
		view.window?.makeFirstResponder(listController.focusTargetView)
		if selectingFirstDocument {
			listController.selectFirstDocumentIfNoneSelected()
		}
	}

	/// What Share hands over: a copy of the selected document's original under its suggested name,
	/// once the reader holds the original on this Mac, and nothing before.
	func shareableItems() -> [Any] {
		guard let document = latestNavigation.selectedDocument,
		      let loaded = readerController.loadedOriginal, loaded.document == document,
		      let copy = try? actions.namedCopy(
		      	of: loaded.file,
		      	suggestedFileName: detailLoader.detail?.suggestedFileName ?? "\(document.value).pdf"
		      )
		else {
			return []
		}
		return [copy]
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

	@objc func removeShownFolderAction(_: Any?) {
		pageController.requestFolderRemoval()
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

	/// A command of a row's context menu. The row need not be the selected one, so the commands that
	/// need the document's detail read it first.
	func perform(_ command: DocumentRowCommand, on row: DocumentRow) {
		let document = row.document
		switch command {
		case .openOriginal:
			openDocument(document)
		case .quickLook:
			// The panel follows the selection, and grows out of the selected row's picture.
			onNavigationChange? { $0.selectedDocument = document }
			actions.toggleQuickLook(for: document, title: row.title, window: view.window)
		case .share:
			// The menu holds the system's share submenu, which hands over the item itself.
			break
		case .copy:
			actions.copyFile(document, suggestedFileName: row.suggestedFileName, window: view.window)
		case .exportOriginal:
			actions.export(document, suggestedFileName: row.suggestedFileName, window: view.window)
		case .moreFromSender:
			Task {
				if let sender = try? await queries.document(document)?.sender {
					navigateToScope(sender)
				}
			}
		case .openInBrowser:
			Task {
				if let page = try? await queries.document(document)?.archivePage, let url = URL(string: page) {
					NSWorkspace.shared.open(url)
				}
			}
		}
	}

	/// A person's choice of the original or the text, which also ends a turn the reader made itself.
	func setReaderTab(_ tab: ReaderTab) {
		onNavigationChange? { navigation in
			navigation.readerTab = tab
			navigation.textShownForMatch = nil
		}
	}

	func showTextForMatch(in document: DocumentIdentifier) {
		guard document == latestNavigation.selectedDocument, latestNavigation.shownReaderTab == .original else {
			return
		}
		onNavigationChange? { $0.textShownForMatch = document }
	}

	/// Shows the reader's next match, or its previous one for a negative step.
	func showMatch(advancingBy step: Int) {
		readerController.showMatch(advancingBy: step)
	}

	var readerHasMatches: Bool {
		latestWorkspace?.detailMode == .documents && readerController.hasMatches
	}

	func openDocument(_ document: DocumentIdentifier) {
		actions.openInDefaultApplication(document, window: view.window)
	}

	func previewDocument(_ document: DocumentIdentifier) {
		actions.toggleQuickLook(for: document, title: detailLoader.detail?.title, window: view.window)
	}
}
