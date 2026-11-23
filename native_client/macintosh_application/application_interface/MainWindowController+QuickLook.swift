import AppKit
import QuickLookUI

/// The Quick Look panel takes a data source only from a responder that controls it. The window's
/// controller is in the responder chain whether the list, the reader, or the inspector has the
/// keyboard. The workspace's own split view would be nearer, but NSSplitViewController raises an
/// exception for a split view of a subclass in a titled window.
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
