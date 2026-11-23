import ApplicationBindings
import Foundation
import XCTest
@testable import ApplicationInterface

/// When a request that the copy read the archive has its answer.
final class SynchronizationAnswerTests: XCTestCase {
	/// The copy records whole milliseconds, so a read in the millisecond of the request answers it,
	/// and a read a millisecond earlier does not. The first waited forever when the copy read the
	/// archive 0.194 ms after the request.
	@MainActor
	func testAReadInTheMillisecondOfTheRequestAnswersIt() {
		let requestedAt = Date(timeIntervalSince1970: 1_795_446_436.527_194)

		let sameMillisecond = Self.status(synchronizedAt: Date(timeIntervalSince1970: 1_795_446_436.527))
		let millisecondBefore = Self.status(synchronizedAt: Date(timeIntervalSince1970: 1_795_446_436.526))

		XCTAssertEqual(SynchronizationAnswer.resolve(sameMillisecond, requestedAt: requestedAt), .synchronized)
		XCTAssertNil(SynchronizationAnswer.resolve(millisecondBefore, requestedAt: requestedAt))
	}

	private static func status(synchronizedAt: Date) -> LibraryStatus {
		LibraryStatus(
			revision: 1,
			archive: .configured(
				origin: "https://archive.example.org",
				host: "archive.example.org",
				condition: .connected,
				permission: .readOnly,
				restricted: false
			),
			copy: .complete(synchronizedAt: synchronizedAt),
			contentRevision: 1,
			counts: LibraryCounts(documents: 1, documentsInIngestion: 0, documentsFailed: 0, documentsAwaitingText: 0)
		)
	}
}
