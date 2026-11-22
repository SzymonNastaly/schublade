import Foundation

struct ConditionNotReached: Error, CustomStringConvertible {
	let expectation: String
	let detail: String

	var description: String {
		"Timed out waiting for \(expectation): \(detail)"
	}
}
