import Foundation

/// What becomes of a file a person shares with Schublade: a submission of its own, a HEIC picture
/// as a JPEG, or a refusal for a kind the archive does not take.
public enum ShareIntake {
	/// The archive takes at most 20 files per upload, and the share extension accepts as many.
	public static let fileLimit = 20

	public struct SharedFile: Sendable {
		/// A copy the caller hands over; the intake moves or removes it.
		public let file: URL
		/// The name the sharing application suggested, without its extension.
		public let suggestedName: String?

		public init(file: URL, suggestedName: String?) {
			self.file = file
			self.suggestedName = suggestedName
		}
	}

	/// Converts and enqueues one shared file with its upload claimed, away from the caller's actor.
	/// The share extension starts that upload before it receives the next file, so it holds one
	/// decoded picture at most and leaves no claimed submission waiting for the others.
	@concurrent
	public static func receive(
		_ shared: SharedFile,
		into queue: SubmissionQueue,
		now: Date = .now
	) async throws -> SubmissionEntry {
		do {
			let imported = try DocumentImport.prepare(file: shared.file, suggestedName: shared.suggestedName)
			return try queue.enqueue(
				document: imported.file,
				fileName: imported.fileName,
				kind: imported.kind,
				origin: .share,
				claimingUpload: true,
				now: now
			)
		} catch {
			try? FileManager.default.removeItem(at: shared.file)
			throw error
		}
	}
}
