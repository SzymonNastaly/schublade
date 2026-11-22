import Foundation
import ImageIO
import SubmissionQueue
import UIKit
import UniformTypeIdentifiers
import XCTest

/// What the share extension makes of the files a person shares.
final class ShareIntakeTests: XCTestCase {
	/// A PDF and a HEIC picture become two submissions, the picture a JPEG, and a text file is named.
	/// The PDF's suggested name carries its extension, as Safari's does, and the name sent keeps one.
	func testSharedFilesBecomeSubmissionsAndATextFileIsRefused() async throws {
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let letter = directory.appending(path: "Letter from the Stadtwerke.pdf")
		try Data("%PDF-1.4\nA letter shared from Mail\n%%EOF\n".utf8).write(to: letter)
		let receipt = directory.appending(path: "IMG_0412.heic")
		try Self.writePicture(to: receipt, type: .heic)
		let notes = directory.appending(path: "Notes.txt")
		try Data("Call the Stadtwerke on Monday.".utf8).write(to: notes)
		let queue = SubmissionQueue(root: directory.appending(path: "queue", directoryHint: .isDirectory))

		let reception = await ShareIntake.receive(
			[
				ShareIntake.SharedFile(file: letter, suggestedName: "Letter from the Stadtwerke.pdf"),
				ShareIntake.SharedFile(file: receipt, suggestedName: "Receipt"),
				ShareIntake.SharedFile(file: notes, suggestedName: "Notes"),
			],
			into: queue
		)

		XCTAssertEqual(reception.entries.map(\.manifest.fileName), ["Letter from the Stadtwerke.pdf", "Receipt.jpg"])
		XCTAssertEqual(reception.entries.map(\.manifest.kind), [.pdf, .jpeg])
		XCTAssertEqual(reception.entries.map(\.manifest.origin), [.share, .share])
		XCTAssertEqual(reception.refusedNames, ["Notes.txt"])
		XCTAssertEqual(Set(queue.entries().map(\.id)), Set(reception.entries.map(\.id)))
		let picture = try Data(contentsOf: XCTUnwrap(queue.documentFile(of: reception.entries[1])))
		XCTAssertEqual(Array(picture.prefix(3)), [0xFF, 0xD8, 0xFF])
	}

	private static func writePicture(to file: URL, type: UTType) throws {
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		let picture = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1200), format: format).image { context in
			UIColor.white.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
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
