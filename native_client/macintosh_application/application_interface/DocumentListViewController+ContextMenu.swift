import AppKit
import ApplicationBindings
import ApplicationPresentation

extension DocumentListViewController: NSMenuDelegate {
	/// The menu of the row a person Control-clicked, which need not be the selected one, or of the
	/// selected row for a menu opened from the keyboard or VoiceOver.
	func menuNeedsUpdate(_ menu: NSMenu) {
		fill(menu, forRow: tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow)
	}

	/// Fills a menu with the commands of a document's row, and leaves it empty for a heading.
	func fill(_ menu: NSMenu, forRow position: Int) {
		menu.removeAllItems()
		guard case let .document(row)? = model.row(at: position) else {
			return
		}
		for (index, group) in DocumentRowCommand.groups(for: row).enumerated() {
			if index > 0 {
				menu.addItem(.separator())
			}
			for command in group {
				menu.addItem(menuItem(command, for: row))
			}
		}
	}

	private func menuItem(_ command: DocumentRowCommand, for row: DocumentRow) -> NSMenuItem {
		let item: NSMenuItem
		if command == .share {
			item = NSSharingServicePicker(items: shareableItems(row)).standardShareMenuItem
		} else {
			item = NSMenuItem(title: command.title, action: #selector(rowCommandChosen(_:)), keyEquivalent: "")
			item.target = self
			item.representedObject = RowCommandChoice(command: command, row: row)
		}
		item.image = NSImage(systemSymbolName: command.symbolName, accessibilityDescription: nil)
		return item
	}

	@objc private func rowCommandChosen(_ sender: NSMenuItem) {
		guard let choice = sender.representedObject as? RowCommandChoice else {
			return
		}
		onRowCommand(choice.command, choice.row)
	}
}

/// A command and the row it was chosen for, as a menu item carries it.
private final class RowCommandChoice: NSObject {
	let command: DocumentRowCommand
	let row: DocumentRow

	init(command: DocumentRowCommand, row: DocumentRow) {
		self.command = command
		self.row = row
	}
}
