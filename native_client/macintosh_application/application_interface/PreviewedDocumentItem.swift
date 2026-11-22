import Foundation
import QuickLookUI

/// Bridges a cached local original to `QLPreviewPanel`. Quick Look reads an item from its own
/// threads, and a main-actor conformance would end the application on Swift's isolation check
/// there, so the conformance is nonisolated over constants.
final class PreviewedDocumentItem: NSObject {
	nonisolated let previewItemURL: URL?
	nonisolated let previewItemTitle: String?

	init(url: URL, title: String) {
		previewItemURL = url
		previewItemTitle = title
	}
}

extension PreviewedDocumentItem: nonisolated QLPreviewItem {}
