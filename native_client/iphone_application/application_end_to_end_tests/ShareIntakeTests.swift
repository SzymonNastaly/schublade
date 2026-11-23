import Foundation
import ImageIO
import SubmissionQueue
import UIKit
import UniformTypeIdentifiers
import XCTest

final class ShareIntakeTests: XCTestCase {
	/// The PDF's copy carries no extension, as a provider's file may not, while its suggested name
	/// carries one, as Safari's does, and the name sent keeps one.
	func testSharedFilesBecomeClaimedSubmissionsAndATextFileIsRefused() async throws {
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let letter = directory.appending(path: "Letter from the Stadtwerke")
		try Data("%PDF-1.4\nA letter shared from Mail\n%%EOF\n".utf8).write(to: letter)
		let receipt = directory.appending(path: "IMG_0412.heic")
		try Self.writePicture(to: receipt, type: .heic)
		let notes = directory.appending(path: "Notes.txt")
		try Data("Call the Stadtwerke on Monday.".utf8).write(to: notes)
		let queue = SubmissionQueue(root: directory.appending(path: "queue", directoryHint: .isDirectory))
		let sharedAt = Date(timeIntervalSince1970: 1_795_420_800)

		let entries = try await [
			ShareIntake.SharedFile(file: letter, type: .pdf, suggestedName: "Letter from the Stadtwerke.pdf"),
			ShareIntake.SharedFile(file: receipt, type: .heic, suggestedName: "Receipt"),
		].asyncMap { try await ShareIntake.receive($0, picture: nil, into: queue, now: sharedAt) }
		var refusal: (any Error)?
		do {
			_ = try await ShareIntake.receive(
				ShareIntake.SharedFile(file: notes, type: .plainText, suggestedName: "Notes"),
				picture: nil,
				into: queue,
				now: sharedAt
			)
		} catch {
			refusal = error
		}

		XCTAssertEqual(entries.map(\.manifest.fileName), ["Letter from the Stadtwerke.pdf", "Receipt.jpg"])
		XCTAssertEqual(entries.map(\.manifest.kind), [.pdf, .jpeg])
		XCTAssertEqual(entries.map(\.manifest.origin), [.share, .share])
		XCTAssertEqual(entries.map(\.manifest.uploadClaimedAt), [sharedAt, sharedAt])
		XCTAssertEqual(refusal as? DocumentImport.ImportFailure, .unacceptedKind("Notes.txt"))
		XCTAssertEqual(Set(queue.entries().map(\.id)), Set(entries.map(\.id)))
		let picture = try Data(contentsOf: XCTUnwrap(queue.documentFile(of: entries[1])))
		XCTAssertEqual(Array(picture.prefix(3)), [0xFF, 0xD8, 0xFF])
	}

	/// A picture of the iPhone's 48-megapixel camera is about 190 MB decoded, above the 120 MB a share
	/// extension may hold, so the conversion decodes at most 4,000 pixels on the longer side, more
	/// than the 3,508 of an A4 page at 300 dots per inch.
	func testALargeSharedPictureBecomesAJPEGOfAtMostFourThousandPixels() async throws {
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let photograph = directory.appending(path: "IMG_0413.heic")
		try Self.writePicture(to: photograph, type: .heic, size: CGSize(width: 3000, height: 6000))
		let queue = SubmissionQueue(root: directory.appending(path: "queue", directoryHint: .isDirectory))

		let entry = try await ShareIntake.receive(
			ShareIntake.SharedFile(file: photograph, type: .heic, suggestedName: "Receipt"),
			picture: nil,
			into: queue
		)

		let source = try XCTUnwrap(CGImageSourceCreateWithURL(XCTUnwrap(queue.documentFile(of: entry)) as CFURL, nil))
		XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
		let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
		XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2000)
		XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 4000)
	}

	private static func writePicture(
		to file: URL,
		type: UTType,
		size: CGSize = CGSize(width: 800, height: 1200)
	) throws {
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		let picture = UIGraphicsImageRenderer(size: size, format: format).image { context in
			UIColor.white.setFill()
			context.fill(CGRect(origin: .zero, size: size))
			NSAttributedString(
				string: "Bäckerei Schmidt 4,20 EUR",
				attributes: [.font: UIFont.systemFont(ofSize: 48)]
			).draw(at: CGPoint(x: 60, y: 100))
		}
		let destination = try XCTUnwrap(
			CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil),
			"ImageIO writes \(type.identifier)"
		)
		try CGImageDestinationAddImage(destination, XCTUnwrap(picture.cgImage), nil)
		XCTAssertTrue(CGImageDestinationFinalize(destination))
	}
}

private extension Array {
	func asyncMap<Transformed>(_ transform: (Element) async throws -> Transformed) async rethrows -> [Transformed] {
		var transformed: [Transformed] = []
		for element in self {
			try await transformed.append(transform(element))
		}
		return transformed
	}
}
