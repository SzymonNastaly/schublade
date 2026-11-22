import Foundation
import SubmissionQueue
import XCTest

final class SubmissionQueueTests: XCTestCase {
	/// Another process may record an answer after the archived one, such as the share extension's
	/// late upload or a body prepared after the document left.
	func testAnArchivedAnswerStandsWhateverIsRecordedAfterIt() throws {
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let letter = directory.appending(path: "letter.pdf")
		try Data("%PDF-1.4\nA letter answered twice\n%%EOF\n".utf8).write(to: letter)
		let queue = SubmissionQueue(root: directory.appending(path: "queue", directoryHint: .isDirectory))
		let entry = try queue.enqueue(document: letter, fileName: "Letter.pdf", kind: .pdf, origin: .share)
		let archivedAt = Date(timeIntervalSince1970: 1_795_420_800)

		try queue.record(
			.archived(document: "0b7c4c1e-5d1f-4b8e-9a43-2f6d1c0e7a51", alreadyHeld: false, answeredAt: archivedAt),
			for: entry.id
		)
		try queue.record(.rejected(reason: "The file is no longer on this iPhone.", answeredAt: .now), for: entry.id)
		try queue.receive(nil, for: entry.id)

		XCTAssertEqual(
			queue.entry(entry.id)?.answer,
			.archived(document: "0b7c4c1e-5d1f-4b8e-9a43-2f6d1c0e7a51", alreadyHeld: false, answeredAt: archivedAt)
		)
	}
}
