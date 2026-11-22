import AppKit

/// Document table view subclass handling Space for Quick Look and Return for opening in the
/// default application.
final class DocumentListTableView: NSTableView {
	var onQuickLook: (() -> Void)?
	var onOpenSelectedDocument: (() -> Void)?

	override func keyDown(with event: NSEvent) {
		if event.keyCode == 49 {
			onQuickLook?()
			return
		}
		if event.keyCode == 36 || event.keyCode == 76 {
			onOpenSelectedDocument?()
			return
		}
		super.keyDown(with: event)
	}
}
