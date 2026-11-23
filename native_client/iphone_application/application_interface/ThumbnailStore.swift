import ApplicationBindings
import ImageIO
import UIKit

/// Keeps the first-page pictures of the rows in memory, reads each once, and decodes it away from
/// the main actor. A document without a picture is remembered until the copy changes; a refusal of
/// the moment, such as an unreachable archive, is asked again.
final class ThumbnailStore {
	/// Three times the 58 points of a row's picture at the default text size.
	nonisolated static let maximumPixelSize = 174
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
		return RowPicture.framed(picture)
	}
}
