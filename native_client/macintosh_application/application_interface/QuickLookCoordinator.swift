import AppKit
import QuickLookUI

/// Presents Quick Look for the currently selected document without leaking panel state across tabs.
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource {
	private var currentItem: PreviewedDocumentItem?

	func togglePreview(for item: PreviewedDocumentItem) {
		currentItem = item
		guard let panel = QLPreviewPanel.shared() else {
			return
		}
		if panel.isVisible {
			panel.orderOut(nil)
			return
		}
		panel.dataSource = self
		panel.reloadData()
		panel.makeKeyAndOrderFront(nil)
	}

	func updatePreviewIfVisible(item: PreviewedDocumentItem?) {
		currentItem = item
		guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else {
			return
		}
		if item != nil {
			panel.dataSource = self
			panel.reloadData()
		} else {
			panel.orderOut(nil)
		}
	}

	func numberOfPreviewItems(in _: QLPreviewPanel?) -> Int {
		currentItem == nil ? 0 : 1
	}

	func previewPanel(_: QLPreviewPanel?, previewItemAt _: Int) -> (any QLPreviewItem)? {
		currentItem
	}
}
