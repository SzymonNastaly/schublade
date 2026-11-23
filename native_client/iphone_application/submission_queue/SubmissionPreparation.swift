import ApplicationBindings
import Foundation

/// A submission's body written and the request that sends it, or the answer to record in its place
/// when it cannot be sent as it is.
public enum SubmissionPreparation: Sendable {
	case prepared(DocumentSubmissionRequest, attempt: SubmissionAttempt, body: URL)
	case answered(SubmissionAnswerRecord)
}

/// One upload of a submission. Each has a body file of its own, because after the share
/// extension's claim lapsed the application sends a submission whose upload in the extension's
/// session may still wait to read its body. The upload's task carries the attempt as its
/// description, so whichever process receives the answer removes that body and no other.
public struct SubmissionAttempt: Hashable, Sendable {
	public let submission: UUID
	public let identifier: UUID

	public init(submission: UUID) {
		self.submission = submission
		identifier = UUID()
	}

	/// The attempt that a task's description names, nil for a task that names none.
	public init?(taskDescription: String?) {
		let parts = taskDescription?.split(separator: " ").compactMap { UUID(uuidString: String($0)) } ?? []
		guard parts.count == 2 else {
			return nil
		}
		submission = parts[0]
		identifier = parts[1]
	}

	public var taskDescription: String {
		"\(submission.uuidString) \(identifier.uuidString)"
	}
}

public extension SubmissionQueue {
	/// Writes the body of `entry` with the token that `credentials` holds for `archiveOrigin`, away
	/// from the caller's actor, since a scan's body can hold 25 MB. The token is read now, because
	/// each attempt's body is removed with its answer. A submission whose bytes are gone keeps the
	/// answer it holds, such as the archived one that another process recorded meanwhile.
	@concurrent
	func prepare(
		_ entry: SubmissionEntry,
		archiveOrigin: String,
		credentials: CredentialStorage
	) async -> SubmissionPreparation {
		guard let document = documentFile(of: entry) else {
			return .answered(
				self.entry(entry.id)?.answer
					?? .rejected(reason: "The file is no longer on this iPhone.", answeredAt: .now)
			)
		}
		let attempt = SubmissionAttempt(submission: entry.id)
		let body = bodyFile(of: attempt)
		do {
			let request = try prepareDocumentSubmission(
				archiveOrigin: archiveOrigin,
				credentialStorage: credentials,
				documentPath: document.path(percentEncoded: false),
				fileName: entry.manifest.fileName,
				mediaType: entry.manifest.kind.mediaType,
				destinationPath: body.path(percentEncoded: false)
			)
			return .prepared(request, attempt: attempt, body: body)
		} catch let refusal as SubmissionPreparationRefusal {
			try? FileManager.default.removeItem(at: body)
			return .answered(SubmissionAnswerRecord(refusal: refusal))
		} catch {
			try? FileManager.default.removeItem(at: body)
			return .answered(SubmissionAnswerRecord(refusal: .DocumentUnreadable(detail: String(describing: error))))
		}
	}
}
