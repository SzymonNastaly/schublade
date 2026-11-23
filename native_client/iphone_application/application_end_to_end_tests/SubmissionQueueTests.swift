import Foundation
import SubmissionQueue
import XCTest

final class SubmissionQueueTests: XCTestCase {
	private static let document = "0b7c4c1e-5d1f-4b8e-9a43-2f6d1c0e7a51"
	private static let archivedAt = Date(timeIntervalSince1970: 1_795_420_800)

	/// Another process may record an answer after the archived one, such as the share extension's
	/// late upload or a body prepared after the document left.
	func testAnArchivedAnswerStandsWhateverIsRecordedAfterIt() throws {
		let queue = try Self.queue()
		let entry = try Self.enqueueLetter(into: queue)

		try queue.record(
			.archived(document: Self.document, alreadyHeld: false, answeredAt: Self.archivedAt),
			for: entry.id
		)
		try queue.record(.rejected(reason: "The file is no longer on this iPhone.", answeredAt: .now), for: entry.id)
		try queue.receive(nil, for: entry.id)

		XCTAssertEqual(
			queue.entry(entry.id)?.answer,
			.archived(document: Self.document, alreadyHeld: false, answeredAt: Self.archivedAt)
		)
	}

	/// When both processes send one submission, the archive answers one upload as newly archived and
	/// the other as already held, in either order, and the submission shows the document as new.
	func testANewlyArchivedAnswerStandsOverAnAlreadyHeldOneInEitherOrder() throws {
		let queue = try Self.queue()
		let heldAnsweredLast = try Self.enqueueLetter(into: queue)
		let newlyAnsweredLast = try Self.enqueueLetter(into: queue)
		let newly = SubmissionAnswerRecord.archived(
			document: Self.document,
			alreadyHeld: false,
			answeredAt: Self.archivedAt
		)
		let held = SubmissionAnswerRecord.archived(
			document: Self.document,
			alreadyHeld: true,
			answeredAt: Self.archivedAt.addingTimeInterval(5)
		)

		try queue.record(newly, for: heldAnsweredLast.id)
		try queue.record(held, for: heldAnsweredLast.id)
		try queue.record(held, for: newlyAnsweredLast.id)
		try queue.record(newly, for: newlyAnsweredLast.id)

		XCTAssertEqual(queue.entry(heldAnsweredLast.id)?.answer, newly)
		XCTAssertEqual(queue.entry(newlyAnsweredLast.id)?.answer, newly)
	}

	private static func queue() throws -> SubmissionQueue {
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return SubmissionQueue(root: directory.appending(path: "queue", directoryHint: .isDirectory))
	}

	private static func enqueueLetter(into queue: SubmissionQueue) throws -> SubmissionEntry {
		let letter = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
		try Data("%PDF-1.4\nA letter answered twice \(UUID().uuidString)\n%%EOF\n".utf8).write(to: letter)
		return try queue.enqueue(document: letter, fileName: "Letter.pdf", kind: .pdf, origin: .share)
	}
}
