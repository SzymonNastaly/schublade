import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// What a client reads from a document before it sends it, so that the archive stores it and need
/// not read the document itself: the text of each page and the first page as a small picture.
public struct DocumentContents: Equatable, Sendable {
	public enum OriginalKind: Sendable {
		case pdf
		case picture
	}

	/// The text of each page in page order, empty for a page nothing could be read from. Empty when
	/// no page gave any text, so the archive reads the original itself.
	public let pageTexts: [String]
	/// The first page or the picture as a JPEG, or nil when it could not be drawn.
	public let thumbnail: Data?

	/// Never fails: whatever cannot be read is left out. Recognition holds the calling thread for
	/// about a second per scanned page, so call it off the main thread. Safe on a thread without an
	/// autorelease pool, such as a Rust thread, because it drains its own.
	public static func read(_ original: Data, kind: OriginalKind) -> DocumentContents {
		autoreleasepool {
			switch kind {
			case .pdf: readPortableDocument(original)
			case .picture: readPicture(original)
			}
		}
	}

	/// Each page's text layer when it is readable, and otherwise what Vision recognizes on the page.
	private static func readPortableDocument(_ original: Data) -> DocumentContents {
		guard let document = PDFDocument(data: original) else {
			return DocumentContents(pageTexts: [], thumbnail: nil)
		}
		let pages = (0 ..< document.pageCount).compactMap { document.page(at: $0) }
		let pageTexts = pages.map { page in
			autoreleasepool {
				let layer = (page.string ?? "").replacingOccurrences(of: "\r\n", with: "\n")
					.replacingOccurrences(of: "\r", with: "\n")
				if ReadableTextLayer.admits(layer) {
					return layer
				}
				return page.pageRef
					.flatMap { PagePicture.drawn($0, longerSide: PageTextRecognition.pixelLimit) }
					.map(PageTextRecognition.text(of:)) ?? ""
			}
		}
		let thumbnail = pages.first?.pageRef
			.flatMap { PagePicture.drawn($0, longerSide: PagePicture.thumbnailPixelLimit) }
			.flatMap(PagePicture.jpeg(of:))
		return DocumentContents(pageTexts: pageTexts.allSatisfy(\.isEmpty) ? [] : pageTexts, thumbnail: thumbnail)
	}

	/// What Vision recognizes on the upright picture as its one page, and the picture reduced.
	private static func readPicture(_ original: Data) -> DocumentContents {
		guard let source = CGImageSourceCreateWithData(original as CFData, nil) else {
			return DocumentContents(pageTexts: [], thumbnail: nil)
		}
		let text = PagePicture.upright(source, longerSide: PageTextRecognition.pixelLimit)
			.map(PageTextRecognition.text(of:)) ?? ""
		let thumbnail = PagePicture.upright(source, longerSide: PagePicture.thumbnailPixelLimit)
			.flatMap(PagePicture.onWhite(_:))
			.flatMap(PagePicture.jpeg(of:))
		return DocumentContents(pageTexts: text.isEmpty ? [] : [text], thumbnail: thumbnail)
	}
}
