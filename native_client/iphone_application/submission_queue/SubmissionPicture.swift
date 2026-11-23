import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The first page of a submission as a small picture, which the row of the submission shows from
/// the moment it is created until the archive's own picture of the document replaces it. Every
/// decode is bounded by the picture's size, because the share extension is ended above about 120 MB.
public enum SubmissionPicture {
	/// The longer side in pixels: three times the largest picture a row draws.
	public static let pixelLimit = 312
	static let compressionQuality = 0.8

	/// The picture of a file the archive accepts: a picture decoded by ImageIO at the limit, upright,
	/// or the first page of a PDF, which Quick Look renders outside this process. Nil when neither
	/// can draw the file, and the row then shows a placeholder.
	@concurrent
	public static func make(from file: URL, kind: SubmissionFileKind) async -> CGImage? {
		guard kind == .pdf else {
			return decoded(from: file)
		}
		let request = QLThumbnailGenerator.Request(
			fileAt: file,
			size: CGSize(width: pixelLimit, height: pixelLimit),
			scale: 1,
			representationTypes: .thumbnail
		)
		return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
	}

	/// A page reduced to the limit and drawn on white, such as the first page of a scan. A JPEG has
	/// no transparency, and a transparent picture would otherwise turn black in it.
	public static func reduced(_ page: CGImage) -> CGImage? {
		let scale = min(Double(pixelLimit) / Double(max(page.width, page.height, 1)), 1)
		let width = max(Int((Double(page.width) * scale).rounded()), 1)
		let height = max(Int((Double(page.height) * scale).rounded()), 1)
		guard let context = CGContext(
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
		context.draw(page, in: CGRect(x: 0, y: 0, width: width, height: height))
		return context.makeImage()
	}

	private static func decoded(from file: URL) -> CGImage? {
		let decoding = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
		] as CFDictionary
		guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else {
			return nil
		}
		return CGImageSourceCreateThumbnailAtIndex(source, 0, decoding)
	}

	static func write(_ picture: CGImage, to file: URL) -> Bool {
		guard let destination = CGImageDestinationCreateWithURL(
			file as CFURL,
			UTType.jpeg.identifier as CFString,
			1,
			nil
		) else {
			return false
		}
		let options = [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
		CGImageDestinationAddImage(destination, picture, options)
		return CGImageDestinationFinalize(destination)
	}
}
