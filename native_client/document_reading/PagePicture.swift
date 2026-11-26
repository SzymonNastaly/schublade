import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A page or a picture drawn upright on white at a size, and its JPEG.
enum PagePicture {
	/// The longer side of the picture the archive lists a document with.
	static let thumbnailPixelLimit = 480

	/// The page's crop box turned by its rotation and scaled so its longer side is `longerSide`.
	static func drawn(_ page: CGPDFPage, longerSide: Int) -> CGImage? {
		let box = page.getBoxRect(.cropBox)
		let turned = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
		guard turned.width > 0, turned.height > 0 else {
			return nil
		}
		let scale = CGFloat(longerSide) / max(turned.width, turned.height)
		guard let context = whiteContext(
			width: Int((turned.width * scale).rounded()),
			height: Int((turned.height * scale).rounded())
		) else {
			return nil
		}
		context.scaleBy(x: scale, y: scale)
		// The rectangle has the turned page's own size, so the transform only rotates and moves.
		context.concatenate(page.getDrawingTransform(
			.cropBox,
			rect: CGRect(origin: .zero, size: turned),
			rotate: 0,
			preserveAspectRatio: true
		))
		context.drawPDFPage(page)
		return context.makeImage()
	}

	/// The first picture of a source at most `longerSide` pixels on its longer side, turned by its
	/// EXIF orientation, which only a thumbnail of ImageIO applies.
	static func upright(_ source: CGImageSource, longerSide: Int) -> CGImage? {
		let decoding = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: longerSide,
		] as CFDictionary
		return CGImageSourceCreateThumbnailAtIndex(source, 0, decoding)
	}

	/// The picture drawn on white, because a JPEG has no transparency and a transparent pixel would
	/// turn black in it.
	static func onWhite(_ picture: CGImage) -> CGImage? {
		let context = whiteContext(width: picture.width, height: picture.height)
		context?.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
		return context?.makeImage()
	}

	static func jpeg(of picture: CGImage) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(
			data as CFMutableData,
			UTType.jpeg.identifier as CFString,
			1,
			nil
		) else {
			return nil
		}
		CGImageDestinationAddImage(
			destination,
			picture,
			[kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
		)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}

	private static func whiteContext(width: Int, height: Int) -> CGContext? {
		guard width > 0, height > 0, let context = CGContext(
			data: nil,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
		) else {
			return nil
		}
		context.interpolationQuality = .high
		context.setFillColor(CGColor(gray: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		return context
	}
}
