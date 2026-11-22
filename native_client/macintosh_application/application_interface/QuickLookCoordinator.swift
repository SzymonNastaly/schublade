import AppKit
import QuickLookUI

/// The one Quick Look panel of the application and the document it shows. The panel may take a
/// data source only from a responder that controls it, or AppKit raises an exception that ends the
/// application, so the document table takes control and hands the panel to this coordinator.
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource {
	static let shared = QuickLookCoordinator()

	private var currentItem: PreviewedDocumentItem?
	private var controlledPanel: QLPreviewPanel?

	var isPreviewVisible: Bool {
		QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
	}

	func togglePreview(for item: PreviewedDocumentItem) {
		currentItem = item
		guard let panel = QLPreviewPanel.shared() else {
			return
		}
		if panel.isVisible {
			panel.orderOut(nil)
		} else {
			panel.makeKeyAndOrderFront(nil)
		}
	}

	func updatePreviewIfVisible(item: PreviewedDocumentItem?) {
		currentItem = item
		guard let panel = controlledPanel, panel.isVisible else {
			return
		}
		if item == nil {
			panel.orderOut(nil)
		} else {
			panel.reloadData()
		}
	}

	/// Called by the responder that took control of the panel.
	func beginControl(of panel: QLPreviewPanel) {
		controlledPanel = panel
		panel.dataSource = self
		panel.reloadData()
	}

	func endControl(of panel: QLPreviewPanel) {
		panel.dataSource = nil
		controlledPanel = nil
	}

	func numberOfPreviewItems(in _: QLPreviewPanel?) -> Int {
		currentItem == nil ? 0 : 1
	}

	func previewPanel(_: QLPreviewPanel?, previewItemAt _: Int) -> (any QLPreviewItem)? {
		currentItem
	}
}
