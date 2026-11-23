import ApplicationBindings
import ImageIO
import UIKit

/// Keeps the first-page pictures of the rows in memory, reads each once, and decodes it away from
/// the main actor. At most four reads run at once, the picture asked for last first, so the rows in
/// view come before those a fast scroll passed, and a row scrolled away gives up a read that has not
/// started. A document without a picture is remembered until the copy changes; a refusal of the
/// moment, such as an unreachable archive, is asked again after a pause.
final class ThumbnailStore {
	/// Three times the 58 points of a row's picture at the default text size.
	nonisolated static let maximumPixelSize = 174
	private static let maximumPictures = 300
	private static let simultaneousReads = 4
	/// Offline, every reconfiguration of a row would otherwise ask the copy again.
	private static let unansweredPause: TimeInterval = 30

	private enum Answer {
		case picture(UIImage)
		case absent
		case unanswered
	}

	private let gateway: ApplicationGateway
	/// At most `maximumPictures`, of about 100 KB each; the first read leaves first.
	private var pictures: [DocumentIdentifier: UIImage] = [:]
	private var readOrder: [DocumentIdentifier] = []
	/// The documents whose pictures rows wait for, the newest last, with what each row does once its
	/// picture arrived.
	private var waiting: [DocumentIdentifier] = []
	private var arrivals: [DocumentIdentifier: (DocumentIdentifier) -> Void] = [:]
	private var reading: Set<DocumentIdentifier> = []
	private var absent: Set<DocumentIdentifier> = []
	private var unansweredAt: [DocumentIdentifier: Date] = [:]
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
		unansweredAt.removeAll()
	}

	/// The picture when it was read already. Otherwise it queues its reading and calls `loaded` once
	/// a picture arrived, so the row can show it.
	func picture(for document: DocumentIdentifier, loaded: @escaping (DocumentIdentifier) -> Void) -> UIImage? {
		if let picture = pictures[document] {
			return picture
		}
		if let asked = unansweredAt[document], Date.now.timeIntervalSince(asked) < Self.unansweredPause {
			return nil
		}
		guard !absent.contains(document), !reading.contains(document) else {
			return nil
		}
		waiting.removeAll { $0 == document }
		waiting.append(document)
		arrivals[document] = loaded
		startReads()
		return nil
	}

	/// A row scrolled away, so its picture is read only when it shows again.
	func forget(_ document: DocumentIdentifier) {
		waiting.removeAll { $0 == document }
		arrivals[document] = nil
	}

	private func startReads() {
		while reading.count < Self.simultaneousReads, let document = waiting.popLast() {
			reading.insert(document)
			let loaded = arrivals.removeValue(forKey: document)
			Task {
				let answer = await read(document)
				reading.remove(document)
				switch answer {
				case let .picture(picture):
					keep(picture, for: document)
					loaded?(document)
				case .absent:
					absent.insert(document)
				case .unanswered:
					unansweredAt[document] = .now
				}
				startReads()
			}
		}
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
