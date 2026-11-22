import AppKit
import ImageIO
import PDFKit

/// Loads PDFs and raster images away from the main actor so the reader never blocks scrolling.
enum PortableDocumentLoader {
	@concurrent
	static func openPortableDocument(atPath path: String) async -> sending PDFDocument? {
		PDFDocument(url: URL(fileURLWithPath: path))
	}

	@concurrent
	static func decodeImage(atPath path: String) async -> sending CGImage? {
		let url = URL(fileURLWithPath: path)
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
			return nil
		}
		// A thumbnail without a size limit is the whole image, and only a thumbnail applies the EXIF
		// orientation, without which a phone's photograph stands sideways.
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
		]
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
	}
}
