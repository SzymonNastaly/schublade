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
	/// Whether a page that only recognition reads was left out, because the read was asked to
	/// recognize nothing.
	public let awaitsRecognition: Bool

	/// Never fails: whatever cannot be read is left out. Recognition holds the calling thread for
	/// about a second per scanned page and peaks near 200 MB, so call it off the main thread, and
	/// pass `recognizing: false` where memory is scarce, as in a share extension. Safe on a thread
	/// without an autorelease pool, such as a Rust thread, because it drains its own.
	public static func read(_ original: Data, kind: OriginalKind, recognizing: Bool = true) -> DocumentContents {
		autoreleasepool {
			switch kind {
			case .pdf: readPortableDocument(original, recognizing: recognizing)
			case .picture: readPicture(original, recognizing: recognizing)
			}
		}
	}

	/// Each page's text layer when it is readable, and otherwise what Vision recognizes on the page.
	private static func readPortableDocument(_ original: Data, recognizing: Bool) -> DocumentContents {
		guard let document = PDFDocument(data: original) else {
			return DocumentContents(pageTexts: [], thumbnail: nil, awaitsRecognition: false)
		}
		let pages = (0 ..< document.pageCount).compactMap { document.page(at: $0) }
		var awaitsRecognition = false
		let pageTexts = pages.map { page in
			autoreleasepool {
				let layer = (page.string ?? "").replacingOccurrences(of: "\r\n", with: "\n")
					.replacingOccurrences(of: "\r", with: "\n")
				if ReadableTextLayer.admits(layer) {
					return layer
				}
				guard recognizing else {
					awaitsRecognition = true
					return ""
				}
				return page.pageRef
					.flatMap { PagePicture.drawn($0, longerSide: PageTextRecognition.pixelLimit) }
					.map(PageTextRecognition.text(of:)) ?? ""
			}
		}
		let thumbnail = pages.first?.pageRef
			.flatMap { PagePicture.drawn($0, longerSide: PagePicture.thumbnailPixelLimit) }
			.flatMap(PagePicture.jpeg(of:))
		return DocumentContents(
			pageTexts: pageTexts.allSatisfy(\.isEmpty) ? [] : pageTexts,
			thumbnail: thumbnail,
			awaitsRecognition: awaitsRecognition
		)
	}

	/// What Vision recognizes on the upright picture as its one page, and the picture reduced.
	private static func readPicture(_ original: Data, recognizing: Bool) -> DocumentContents {
		guard let source = CGImageSourceCreateWithData(original as CFData, nil) else {
			return DocumentContents(pageTexts: [], thumbnail: nil, awaitsRecognition: false)
		}
		let text = recognizing
			? PagePicture.upright(source, longerSide: PageTextRecognition.pixelLimit).map(PageTextRecognition.text(of:))
			: nil
		let thumbnail = PagePicture.upright(source, longerSide: PagePicture.thumbnailPixelLimit)
			.flatMap { PagePicture.reduced($0, longerSide: PagePicture.thumbnailPixelLimit) }
			.flatMap(PagePicture.jpeg(of:))
		return DocumentContents(
			pageTexts: text.map { $0.isEmpty ? [] : [$0] } ?? [],
			thumbnail: thumbnail,
			awaitsRecognition: !recognizing
		)
	}

	/// The pages of a scan, which are upright pictures already, such as those of the iPhone's
	/// document camera: what Vision recognizes on each, and the first page reduced. The pages are
	/// taken one at a time, so a lazy sequence holds one of them decoded at once.
	public static func read(pages: some Sequence<CGImage>) -> DocumentContents {
		var pageTexts: [String] = []
		var thumbnail: Data?
		for page in pages {
			autoreleasepool {
				if pageTexts.isEmpty {
					thumbnail = PagePicture.reduced(page, longerSide: PagePicture.thumbnailPixelLimit)
						.flatMap(PagePicture.jpeg(of:))
				}
				pageTexts.append(PageTextRecognition.text(of: page))
			}
		}
		return DocumentContents(
			pageTexts: pageTexts.allSatisfy(\.isEmpty) ? [] : pageTexts,
			thumbnail: thumbnail,
			awaitsRecognition: false
		)
	}
}
