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
		let options: [CFString: Any] = [
			kCGImageSourceShouldCacheImmediately: true,
		]
		return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
	}
}
