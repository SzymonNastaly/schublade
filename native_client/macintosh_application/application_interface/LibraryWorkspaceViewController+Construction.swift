import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// The sidebar and the list, built with the workspace's commands before the workspace exists.
extension LibraryWorkspaceViewController {
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
}
