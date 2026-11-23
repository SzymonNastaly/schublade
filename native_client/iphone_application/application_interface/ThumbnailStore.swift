import ApplicationBindings
import ImageIO
import UIKit

/// Keeps the first-page pictures of the rows in memory, reads each once, and decodes it away from
/// the main actor. A document without a picture is remembered until the copy changes; a refusal of
/// the moment, such as an unreachable archive, is asked again.
final class ThumbnailStore {
	/// Three times the 52 points of a row's picture.
	nonisolated static let maximumPixelSize = 156
	private static let maximumPictures = 300

	private enum Answer {
		case picture(UIImage)
		case absent
		case unanswered
	}

	private let gateway: ApplicationGateway
	/// At most `maximumPictures`, of about 100 KB each; the first read leaves first.
	private var pictures: [DocumentIdentifier: UIImage] = [:]
	private var readOrder: [DocumentIdentifier] = []
	private var reading: Set<DocumentIdentifier> = []
	private var absent: Set<DocumentIdentifier> = []
	private var observedRevision: UInt64?

	init(gateway: ApplicationGateway) {
		self.gateway = gateway
	}

	func contentRevisionChanged(to revision: UInt64) {
		guard revision != observedRevision else {
			return
		}
		observedRevision = revision
		absent.removeAll()
	}

	/// The picture when it was read already. Otherwise it starts reading it and calls `loaded` once
	/// a picture arrived, so the row can show it.
	func picture(for document: DocumentIdentifier, loaded: @escaping (DocumentIdentifier) -> Void) -> UIImage? {
		if let picture = pictures[document] {
			return picture
		}
		guard !absent.contains(document), reading.insert(document).inserted else {
			return nil
		}
		Task {
			let answer = await read(document)
			reading.remove(document)
			switch answer {
			case let .picture(picture):
				keep(picture, for: document)
				loaded(document)
			case .absent:
				absent.insert(document)
			case .unanswered:
				break
			}
		}
		return nil
	}

	private func keep(_ picture: UIImage, for document: DocumentIdentifier) {
		pictures[document] = picture
		readOrder.append(document)
		if readOrder.count > Self.maximumPictures {
			pictures[readOrder.removeFirst()] = nil
		}
	}

	private func read(_ document: DocumentIdentifier) async -> Answer {
		let file: LocalFile?
		do throws(RepresentationRefusal) {
			file = try await gateway.thumbnail(document)
		} catch {
			switch error {
			case .DocumentUnknown, .NotAvailableYet, .NoLongerArchived, .ArchiveOutdated:
				return .absent
			case .ArchiveUnreachable, .CredentialRefused, .NotConnected, .ContentDiffers, .StorageFailed, .Application:
				return .unanswered
			}
		}
		guard let file, let picture = await Self.decode(atPath: file.path) else {
			return .absent
		}
		return .picture(picture)
	}

	@concurrent
	private static func decode(atPath path: String) async -> UIImage? {
		guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil) else {
			return nil
		}
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
		]
		guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
			return nil
		}
		return framed(UIImage(cgImage: picture, scale: 3, orientation: .up))
	}

	/// A page is paper, so a picture with a transparent background is drawn on white, which would
	/// otherwise show the dark row through it; and a white page on a white row needs an edge.
	nonisolated static func framed(_ picture: UIImage) -> UIImage {
		let format = UIGraphicsImageRendererFormat()
		format.scale = picture.scale
		return UIGraphicsImageRenderer(size: picture.size, format: format).image { context in
			let bounds = CGRect(origin: .zero, size: picture.size)
			InterfacePalette.paper.setFill()
			context.fill(bounds)
			picture.draw(in: bounds)
			InterfacePalette.pictureEdge.setStroke()
			context.cgContext.setLineWidth(1 / picture.scale)
			context.cgContext.stroke(bounds.insetBy(dx: 0.5 / picture.scale, dy: 0.5 / picture.scale))
		}
	}
}
