import UIKit

/// Writes the pages of a scan as one PDF. Each page is a JPEG placed as it is, so the PDF keeps the
/// compressed bytes, at about 300 dots per inch on A4. A scan above the archive's limit is written
/// again at about 200 dots per inch and a lower quality before it is refused.
nonisolated enum ScanDocumentWriter {
	struct Quality {
		let longestSide: CGFloat
		let dotsPerInch: CGFloat
		let compression: CGFloat
	}

	enum WriteFailure: Error, Equatable {
		/// Even the lower quality holds more bytes than the archive accepts; the file stays written.
		case tooLarge(bytes: UInt64)
		case unwritable(String)
	}

	static let qualities = [
		Quality(longestSide: 3508, dotsPerInch: 300, compression: 0.7),
		Quality(longestSide: 2339, dotsPerInch: 200, compression: 0.5),
	]
	static let byteLimit: UInt64 = 25_000_000

	/// Writes `pages` to `destination` and answers its byte count.
	static func write(pages: [UIImage], to destination: URL) throws(WriteFailure) -> UInt64 {
		var bytes: UInt64 = 0
		for quality in qualities {
			do {
				try UIGraphicsPDFRenderer(bounds: .zero).writePDF(to: destination) { context in
					for page in pages {
						autoreleasepool {
							draw(page, in: context, quality: quality)
						}
					}
				}
				bytes = try UInt64(destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
			} catch {
				throw .unwritable(error.localizedDescription)
			}
			if bytes <= byteLimit {
				return bytes
			}
		}
		throw .tooLarge(bytes: bytes)
	}

	private static func draw(_ page: UIImage, in context: UIGraphicsPDFRendererContext, quality: Quality) {
		let pixels = CGSize(width: page.size.width * page.scale, height: page.size.height * page.scale)
		let scale = min(1, quality.longestSide / max(pixels.width, pixels.height, 1))
		let target = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		format.opaque = true
		let jpeg = UIGraphicsImageRenderer(size: target, format: format)
			.jpegData(withCompressionQuality: quality.compression) { _ in
				page.draw(in: CGRect(origin: .zero, size: target))
			}
		guard let provider = CGDataProvider(data: jpeg as CFData),
		      let image = CGImage(
		      	jpegDataProviderSource: provider,
		      	decode: nil,
		      	shouldInterpolate: true,
		      	intent: .defaultIntent
		      )
		else {
			return
		}
		let points = 72 / quality.dotsPerInch
		let bounds = CGRect(x: 0, y: 0, width: target.width * points, height: target.height * points)
		context.beginPage(withBounds: bounds, pageInfo: [:])
		UIImage(cgImage: image).draw(in: bounds)
	}
}
