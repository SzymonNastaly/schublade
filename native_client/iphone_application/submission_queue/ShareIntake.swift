import Foundation

/// What becomes of the files a person shares with Schublade: each one the archive takes is a
/// submission of its own, a HEIC picture as a JPEG, and the others are named.
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

	public struct Reception: Sendable {
		/// The new submissions, in the order of the shared files.
		public let entries: [SubmissionEntry]
		/// The file names of the shared files the archive does not take or that could not be read.
		public let refusedNames: [String]
	}

	/// Converts and enqueues the first `fileLimit` files one at a time, away from the caller's actor,
	/// so a share extension holds one decoded picture at most.
	@concurrent
	public static func receive(_ files: [SharedFile], into queue: SubmissionQueue) async -> Reception {
		var entries: [SubmissionEntry] = []
		var refusedNames: [String] = []
		for shared in files.prefix(fileLimit) {
			do {
				let imported = try DocumentImport.prepare(file: shared.file, suggestedName: shared.suggestedName)
				try entries.append(queue.enqueue(
					document: imported.file,
					fileName: imported.fileName,
					kind: imported.kind,
					origin: .share
				))
			} catch {
				try? FileManager.default.removeItem(at: shared.file)
				refusedNames.append(shared.file.lastPathComponent)
			}
		}
		return Reception(entries: entries, refusedNames: refusedNames)
	}
}
