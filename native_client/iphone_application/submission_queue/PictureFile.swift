import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture read from a file or written to one. Every decode is bounded, because a photograph of
/// 48 megapixels decoded whole takes about 190 MB, and the share extension is ended above about
/// 120 MB.
public enum PictureFile {
	/// The first picture of a file at most `longerSide` pixels on its longer side, upright: only a
	/// thumbnail applies the EXIF orientation. `cachedImmediately` decodes it now rather than when it
	/// is first drawn. Nil when ImageIO cannot read the file.
	public static func decoded(
		from file: URL,
		longerSide: Int,
		type: UTType? = nil,
		cachedImmediately: Bool = false
	) -> CGImage? {
		let hint = type.map { [kCGImageSourceTypeIdentifierHint: $0.identifier] as CFDictionary }
		let decoding = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: longerSide,
			kCGImageSourceShouldCacheImmediately: cachedImmediately,
		] as CFDictionary
		guard let source = CGImageSourceCreateWithURL(file as CFURL, hint) else {
			return nil
		}
		return CGImageSourceCreateThumbnailAtIndex(source, 0, decoding)
	}

	/// Writes a JPEG, whose `quality` is between 0 and 1. False when the file could not be written.
	public static func writeJPEG(_ picture: CGImage, to file: URL, quality: Double) -> Bool {
		guard let destination = CGImageDestinationCreateWithURL(
			file as CFURL,
			UTType.jpeg.identifier as CFString,
			1,
			nil
		) else {
			return false
		}
		let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
		CGImageDestinationAddImage(destination, picture, options)
		return CGImageDestinationFinalize(destination)
	}
}
