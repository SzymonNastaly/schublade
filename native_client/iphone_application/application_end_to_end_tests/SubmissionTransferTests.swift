import Foundation
import SubmissionQueue
import XCTest

final class SubmissionTransferTests: XCTestCase {
	/// The share extension's session in the application ends after it was let go, and the system's
	/// completion handler of every launch for its events that it still held must be called then.
	func testATransferThatEndsHandsBackEveryCompletionHandlerItHolds() async {
		let firstLaunch = expectation(description: "the completion handler of the launch that created the session")
		let secondLaunch = expectation(description: "the completion handler of a launch while the session ended")
		let firstCompletion: SubmissionTransfer.BackgroundEventsCompletion = { firstLaunch.fulfill() }
		let transfer = SubmissionTransfer(
			configuration: .ephemeral,
			backgroundEventsCompletion: firstCompletion
		) { _, _ in
		} onProgress: { _, _ in
		} onSessionEvent: { _, event in
			if case let .ended(completions) = event {
				Task { @MainActor in
					completions.forEach { $0() }
				}
			}
		}
		XCTAssertTrue(transfer.handleBackgroundEvents { secondLaunch.fulfill() })

		transfer.invalidate()

		await fulfillment(of: [firstLaunch, secondLaunch], timeout: 5)
		XCTAssertFalse(transfer.handleBackgroundEvents {})
	}
}
