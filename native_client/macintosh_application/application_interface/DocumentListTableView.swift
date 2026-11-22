import AppKit
import QuickLookUI

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

	// The Quick Look panel may take its data source only from a responder that controls it.

	override nonisolated func acceptsPreviewPanelControl(_: QLPreviewPanel?) -> Bool {
		true
	}

	override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel?) {
		MainActor.assumeIsolated {
			panel.map { QuickLookCoordinator.shared.beginControl(of: $0) }
		}
	}

	override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel?) {
		MainActor.assumeIsolated {
			panel.map { QuickLookCoordinator.shared.endControl(of: $0) }
		}
	}
}
