import Foundation

/// A condition a test waited for that did not arrive.
struct ConditionNotReached: Error {
	let expectation: String
	let detail: String
}

/// Polls `condition` on the main actor until it holds, for at most 30 seconds.
@MainActor
func waitUntil(_ expectation: String, condition: () -> Bool) async throws {
	let deadline = ContinuousClock.now + .seconds(30)
	while !condition() {
		guard ContinuousClock.now < deadline else {
			throw ConditionNotReached(expectation: expectation, detail: "not within 30 seconds")
		}
		try await Task.sleep(for: .milliseconds(50))
	}
}
