import Foundation
import UniformTypeIdentifiers

/// What becomes of a file a person shares with Schublade: a submission of its own, a HEIC picture
/// as a JPEG, or a refusal for a kind the archive does not take.
public enum ShareIntake {
	/// The most files the share extension takes from one share.
	public static let fileLimit = 20

	public struct SharedFile: Sendable {
		/// A copy the caller hands over; the intake moves or removes it.
		public let file: URL
		/// The type the file was loaded as.
		public let type: UTType
		/// The name the sharing application suggested, with or without its extension.
		public let suggestedName: String?

		public init(file: URL, type: UTType, suggestedName: String?) {
			self.file = file
			self.type = type
			self.suggestedName = suggestedName
		}
	}

	/// Converts, reads, and enqueues one shared file away from the caller's actor. The extension reads
	/// text layers and draws the first page, but recognizes nothing, because recognition peaks near
	/// 200 MB and the system ends an extension above about 120 MB. A file that holds a page only
	/// recognition reads is left unclaimed, and the application reads and sends it when it next
	/// runs; any other file's upload is claimed, and the extension starts it before it receives the
	/// next file, so it leaves no claimed submission waiting for the others.
	@concurrent
	public static func receive(
		_ shared: SharedFile,
		into queue: SubmissionQueue,
		now: Date = .now
	) async throws -> SubmissionEntry {
		do {
			let imported = try DocumentImport.prepare(
				file: shared.file,
				type: shared.type,
				suggestedName: shared.suggestedName
			)
			let contents = imported.kind.contents(of: imported.file, recognizing: false)
			return try queue.enqueue(
				document: imported.file,
				fileName: imported.fileName,
				kind: imported.kind,
				origin: .share,
				contents: contents,
				claimingUpload: contents?.awaitsRecognition != true,
				now: now
			)
		} catch {
			try? FileManager.default.removeItem(at: shared.file)
			throw error
		}
	}
}
