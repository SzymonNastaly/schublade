import AppKit
import ApplicationBindings
import ImageIO

/// Caches decoded first-page document thumbnails in memory and decodes image files off the main actor.
@MainActor
final class PictureStore {
	private static let maximumPixelSize = 160

	private let queries: any LibraryQueries
	private let cache = NSCache<ThumbnailCacheKey, NSImage>()
	private var inFlightTasks: [String: Task<NSImage?, Never>] = [:]
	private var unavailableDocuments: Set<String> = []
	private var observedContentRevision: UInt64 = 0

	init(queries: any LibraryQueries) {
		self.queries = queries
		cache.countLimit = 400
		cache.totalCostLimit = 32 * 1024 * 1024
	}

	func contentRevisionChanged(to revision: UInt64) {
		guard revision != observedContentRevision else {
			return
		}
		observedContentRevision = revision
		unavailableDocuments.removeAll()
	}

	func cachedPicture(for document: DocumentIdentifier) -> NSImage? {
		cache.object(forKey: ThumbnailCacheKey(document.value))
	}

	func picture(for document: DocumentIdentifier) async -> NSImage? {
		let key = ThumbnailCacheKey(document.value)
		if let cached = cache.object(forKey: key) {
			return cached
		}
		if unavailableDocuments.contains(document.value) {
			return nil
		}
		if let existingTask = inFlightTasks[document.value] {
			return await existingTask.value
		}
		let queries = queries
		let identifier = document
		let task = Task<NSImage?, Never> { [weak self] in
			let answer = await Self.loadAndDecode(queries: queries, document: identifier)
			if let self {
				switch answer {
				case let .picture(image):
					let pixelCost = Int(image.size.width * image.size.height * 4)
					cache.setObject(image, forKey: key, cost: max(pixelCost, 1024))
				case .absent:
					unavailableDocuments.insert(identifier.value)
				case .unanswered:
					break
				}
				inFlightTasks.removeValue(forKey: identifier.value)
			}
			return answer.picture
		}
		inFlightTasks[document.value] = task
		return await task.value
	}

	/// What a request for a picture found. Only an absent picture is remembered until the copy
	/// changes; a refusal of the moment, such as an unreachable archive, is asked again.
	private enum PictureAnswer {
		case picture(NSImage)
		case absent
		case unanswered

		var picture: NSImage? {
			if case let .picture(image) = self {
				return image
			}
			return nil
		}
	}

	private static func loadAndDecode(
		queries: any LibraryQueries,
		document: DocumentIdentifier
	) async -> PictureAnswer {
		let localFile: LocalFile?
		do {
			localFile = try await queries.thumbnail(document)
		} catch {
			switch error {
			case .DocumentUnknown, .NotAvailableYet, .NoLongerArchived, .ArchiveOutdated:
				return .absent
			case .ArchiveUnreachable, .CredentialRefused, .NotConnected, .ContentDiffers, .StorageFailed, .Application:
				return .unanswered
			}
		}
		guard let localFile,
		      let cgImage = await decodeThumbnail(atPath: localFile.path, maximumPixelSize: maximumPixelSize)
		else {
			return .absent
		}
		return .picture(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
	}

	@concurrent
	private static func decodeThumbnail(atPath path: String, maximumPixelSize: Int) async -> sending CGImage? {
		let url = URL(fileURLWithPath: path)
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
			return nil
		}
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
		]
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
	}
}
