import ApplicationBindings
import DocumentReading
import Foundation

/// Reads each document the collector sends with PDFKit and Vision. The collector calls it on its
/// own threads, two at once, so its conformance is nonisolated and it holds no state.
final class CollectedDocumentReader: nonisolated DocumentReader {
	nonisolated func read(original: Data, mediaType: DocumentMediaType) -> ApplicationBindings.DocumentReading {
		let kind: DocumentContents.OriginalKind = switch mediaType {
		case .pdf: .pdf
		case .jpeg, .png, .webp: .picture
		}
		let contents = DocumentContents.read(original, kind: kind)
		return ApplicationBindings.DocumentReading(pageTexts: contents.pageTexts, thumbnail: contents.thumbnail)
	}
}
