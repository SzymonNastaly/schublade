import AppKit

/// Find Next and Find Previous step through the matches the reader marks. The window's controller
/// answers them, because it stays in the responder chain while the search field has the keyboard,
/// which is where a person is after typing a search.
extension MainWindowController: NSMenuItemValidation {
	@objc func findNextMatch(_: Any?) {
		workspaceController?.showMatch(advancingBy: 1)
	}

	@objc func findPreviousMatch(_: Any?) {
		workspaceController?.showMatch(advancingBy: -1)
	}

	func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		switch menuItem.action {
		case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
			workspaceController?.readerHasMatches ?? false
		default:
			true
		}
	}
}
