import ApplicationBindings
import Foundation

/// What the archive last answered to a submission, written into `answer.json`. A submission
/// without one has not been answered yet.
public enum SubmissionAnswerRecord: Codable, Equatable, Sendable {
	/// The archive holds the bytes; the document is new unless `alreadyHeld`.
	case archived(document: String, alreadyHeld: Bool, answeredAt: Date)
	/// The archive will never take these bytes as they are.
	case rejected(reason: String, answeredAt: Date)
	/// The archive refused the token, or the token does not permit sending.
	case refusedToken(answeredAt: Date)
	/// No answer or one that says to try again. `attempts` counts the answers of this kind in a row.
	case unavailable(attempts: Int, answeredAt: Date)

	/// When an unavailable submission is sent again: a minute after the first failure, doubling
	/// with each one after, and at most an hour apart.
	public var nextAttempt: Date? {
		guard case let .unavailable(attempts, answeredAt) = self else {
			return nil
		}
		let exponent = min(max(attempts - 1, 0), 6)
		let delay = min(60.0 * Double(1 << exponent), 3600)
		return answeredAt.addingTimeInterval(delay)
	}
}

public extension SubmissionAnswerRecord {
	/// The record of what the archive answered, or of no answer, such as without a network. An
	/// unavailable answer counts on from the unavailable answer before it.
	init(answer: DocumentSubmissionAnswer?, previous: SubmissionAnswerRecord?, answeredAt: Date = .now) {
		switch answer {
		case let .archived(document, alreadyHeld):
			self = .archived(document: document.value, alreadyHeld: alreadyHeld, answeredAt: answeredAt)
		case let .rejected(reason):
			self = .rejected(reason: reason, answeredAt: answeredAt)
		case .tokenRefused, .notPermitted:
			self = .refusedToken(answeredAt: answeredAt)
		case .archiveUnavailable, nil:
			let attempts = if case let .unavailable(attempts, _) = previous {
				attempts + 1
			} else {
				1
			}
			self = .unavailable(attempts: attempts, answeredAt: answeredAt)
		}
	}

	/// The record of a body that could not be prepared, which no attempt would change.
	init(refusal: SubmissionPreparationRefusal, answeredAt: Date = .now) {
		switch refusal {
		case .TokenMissing, .CredentialStorageFailed, .AddressInvalid:
			self = .refusedToken(answeredAt: answeredAt)
		case .DocumentTooLarge:
			self = .rejected(reason: "The file is larger than the 25 MB the archive accepts.", answeredAt: answeredAt)
		case let .DocumentUnreadable(detail), let .BodyUnwritable(detail):
			self = .rejected(reason: "The file could not be read: \(detail)", answeredAt: answeredAt)
		}
	}
}

/// One submission as the queue holds it.
public struct SubmissionEntry: Equatable, Sendable, Identifiable {
	public let manifest: SubmissionManifest
	public let answer: SubmissionAnswerRecord?

	public var id: UUID {
		manifest.identifier
	}
}
