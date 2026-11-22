import ApplicationBindings
import Foundation

/// A submission's body written and the request that sends it, or the answer to record in its place
/// when it cannot be sent as it is.
public enum SubmissionPreparation: Sendable {
	case prepared(DocumentSubmissionRequest, body: URL)
	case answered(SubmissionAnswerRecord)
}

public extension SubmissionQueue {
	/// Writes the body of `entry` with the token that `credentials` holds for `archiveOrigin`, away
	/// from the caller's actor, since a scan's body can hold 25 MB. The token is read now, because
	/// the body is removed with every answer. A submission whose bytes are gone keeps the answer it
	/// holds, such as the archived one that another process recorded meanwhile.
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
		let body = bodyFile(of: entry.id)
		do {
			let request = try prepareDocumentSubmission(
				archiveOrigin: archiveOrigin,
				credentialStorage: credentials,
				documentPath: document.path(percentEncoded: false),
				fileName: entry.manifest.fileName,
				mediaType: entry.manifest.kind.mediaType,
				destinationPath: body.path(percentEncoded: false)
			)
			return .prepared(request, body: body)
		} catch let refusal as SubmissionPreparationRefusal {
			return .answered(SubmissionAnswerRecord(refusal: refusal))
		} catch {
			return .answered(SubmissionAnswerRecord(refusal: .DocumentUnreadable(detail: String(describing: error))))
		}
	}
}
