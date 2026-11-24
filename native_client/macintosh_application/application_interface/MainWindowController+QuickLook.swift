import AppKit
import QuickLookUI

/// The Quick Look panel takes a data source only from a responder that controls it, and the window's
/// controller is in the chain wherever the keyboard is; NSSplitViewController raises for a split view
/// of a subclass in a titled window, so the workspace's split view cannot take it.
extension MainWindowController {
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
