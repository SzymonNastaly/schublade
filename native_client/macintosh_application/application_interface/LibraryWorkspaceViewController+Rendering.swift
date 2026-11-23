import AppKit

/// What the offscreen renderer shows that a person reaches only with the pointer: a row's context
/// menu, and the inspector's rows under the pointer and just copied.
public extension LibraryWorkspaceViewController {
	/// The context menu of the list's row at a position, as a Control-click on it shows the menu.
	func documentRowMenu(atRow position: Int) -> NSMenu {
		let menu = NSMenu()
		listController.fill(menu, forRow: position)
		return menu
	}

	/// Shows the inspector's row of one label under the pointer and another's as just copied, so the
	/// renderer can draw both states.
	func exhibitInspectorRows(underPointer hovered: String?, copied: String?) {
		inspectorController.exhibitRows(underPointer: hovered, copied: copied)
	}
}
