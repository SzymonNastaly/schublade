import Foundation
import QuickLookUI

/// Bridges a cached local document original URL to `QLPreviewPanel`.
final class PreviewedDocumentItem: NSObject, QLPreviewItem {
	let previewItemURL: URL?
	let previewItemTitle: String?

	init(url: URL, title: String) {
		previewItemURL = url
		previewItemTitle = title
	}
}
