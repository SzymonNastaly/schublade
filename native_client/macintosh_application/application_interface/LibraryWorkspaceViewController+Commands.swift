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
			menuItem.state = latestNavigation.readerTab == .original ? .on : .off
			return allowsDocuments
		case #selector(showExtractedTextRepresentation(_:)):
			menuItem.state = latestNavigation.readerTab == .text ? .on : .off
			return allowsDocuments
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
	func wireKeyViewLoop() {
		sidebarController.focusTargetView.nextKeyView = listController.focusTargetView
		listController.focusTargetView.nextKeyView = readerController.focusTargetView
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

	func setReaderTab(_ tab: ReaderTab) {
		onNavigationChange? { $0.readerTab = tab }
	}

	func openDocument(_ document: DocumentIdentifier) {
		actions.openInDefaultApplication(document, window: view.window)
	}

	func previewDocument(_ document: DocumentIdentifier) {
		actions.toggleQuickLook(for: document, title: detailLoader.detail?.title, window: view.window)
	}
}
