import AppKit
import ApplicationBindings
import ApplicationPresentation

/// The sidebar's part of the workspace: where its status line stands, the moves to a destination,
/// and the folder commands of its context menu.
extension LibraryWorkspaceViewController {
	/// From macOS 26 the status line is the sidebar's bottom accessory, so the list scrolls under it
	/// with the system's edge effect. Offscreen, where the glass draws black, it stays pinned.
	static func statusLineIsAccessory(renderMode: InterfaceRenderMode) -> Bool {
		guard #available(macOS 26.0, *) else {
			return false
		}
		return renderMode == .interactive
	}

	func showFolderInFinder(_ folder: FolderIdentifier) {
		guard let root = latestStatuses.collector?.folders.first(where: { $0.folder.identifier == folder })?.folder.root
		else {
			return
		}
		NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root, isDirectory: true)])
	}

	/// Opens the folder's page and asks there, so the removal keeps the page's alert and its state.
	func requestRemoval(of folder: FolderIdentifier) {
		navigate(to: .folder(folder), selecting: nil)
		pageController.requestFolderRemoval()
	}

	/// Moves to a destination from a page, such as a folder's upload or Show Failed Documents.
	func navigate(to destination: NavigationDestination, selecting document: DocumentIdentifier?) {
		onNavigationChange? { navigation in
			navigation.previousDestination = nil
			navigation.destination = destination
			navigation.searchText = ""
			navigation.selectedDocument = document
		}
	}

	func selectSidebarDestination(_ destination: NavigationDestination) {
		onNavigationChange? { navigation in
			navigation.previousDestination = nil
			navigation.destination = destination
			navigation.selectedDocument = nil
		}
	}
}
