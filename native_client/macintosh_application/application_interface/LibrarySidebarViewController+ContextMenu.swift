import AppKit
import ApplicationBindings
import ApplicationPresentation

extension LibrarySidebarViewController: NSMenuDelegate {
	/// A folder offers Show in Finder and Remove Folder…, the folders' heading offers Add Folder…,
	/// and every other row has no menu.
	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
		guard row >= 0 else {
			return
		}
		let clicked = outlineView.item(atRow: row)
		let section = clicked as? SidebarSectionNode
		if section?.presentation.id == SidebarPresentation.foldersSectionIdentifier {
			menu.addItem(contextItem("Add Folder…", "folder.badge.plus", #selector(addFolderChosen), folder: nil))
		}
		guard let item = clicked as? SidebarItemNode, case let .destination(.folder(folder)) = item.presentation.kind
		else {
			return
		}
		menu.addItem(contextItem("Show in Finder", "folder", #selector(showInFinderChosen(_:)), folder: folder))
		menu.addItem(contextItem("Remove Folder…", "minus.circle", #selector(removeFolderChosen(_:)), folder: folder))
	}

	private func contextItem(
		_ title: String,
		_ symbolName: String,
		_ action: Selector,
		folder: FolderIdentifier?
	) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
		item.target = self
		item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
		item.representedObject = folder?.value
		return item
	}

	@objc private func addFolderChosen() {
		onRequestAddFolder()
	}

	@objc private func showInFinderChosen(_ sender: NSMenuItem) {
		if let value = sender.representedObject as? Int64 {
			onShowFolderInFinder(FolderIdentifier(value: value))
		}
	}

	@objc private func removeFolderChosen(_ sender: NSMenuItem) {
		if let value = sender.representedObject as? Int64 {
			onRequestFolderRemoval(FolderIdentifier(value: value))
		}
	}
}
