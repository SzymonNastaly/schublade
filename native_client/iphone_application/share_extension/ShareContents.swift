import Foundation
import SubmissionQueue
import UniformTypeIdentifiers

/// What another application shared: the files Schublade sends, at most as many as the archive takes
/// at a time, and the items it leaves out because the archive does not take their kind.
struct ShareContents {
	struct SharedFile {
		let provider: NSItemProvider
		/// The type the file is loaded as.
		let type: UTType
	}

	let files: [SharedFile]
	let leftOut: [NSItemProvider]
	/// How many files the archive would take beyond its limit.
	let overLimit: Int

	init(items: [Any]) {
		var accepted: [SharedFile] = []
		var leftOut: [NSItemProvider] = []
		for provider in items.compactMap({ $0 as? NSExtensionItem }).flatMap({ $0.attachments ?? [] }) {
			if let type = DocumentImport.preferredType(among: provider.registeredContentTypes) {
				accepted.append(SharedFile(provider: provider, type: type))
			} else if !provider.registeredContentTypes.allSatisfy({ $0.conforms(to: .url) }) {
				// Safari shares the page's address beside its PDF, which is no file a person chose.
				leftOut.append(provider)
			}
		}
		files = Array(accepted.prefix(ShareIntake.fileLimit))
		self.leftOut = leftOut
		overLimit = accepted.count - files.count
	}

	/// The name a person knows a file by: the one the sharing application suggests, or the name of
	/// the file that Files offers without suggesting one.
	static func name(of provider: NSItemProvider) async -> String? {
		if let suggested = provider.suggestedName {
			return suggested
		}
		guard provider.canLoadObject(ofClass: URL.self) else {
			return nil
		}
		let file: URL? = await withCheckedContinuation { continuation in
			_ = provider.loadObject(ofClass: URL.self) { url, _ in
				continuation.resume(returning: url)
			}
		}
		return file?.lastPathComponent
	}

	/// Copies the file a provider offers into a directory of its own under `parent`, because the
	/// provider's file exists only during its callback and two shared files can carry one name.
	static func copy(_ file: SharedFile, into parent: URL) async throws -> URL {
		// Without intermediate directories, so that no copy is made once the sheet removed `parent`.
		let directory = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		return try await withCheckedThrowingContinuation { continuation in
			_ = file.provider.loadFileRepresentation(for: file.type, openInPlace: false) { url, _, error in
				guard let url else {
					continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
					return
				}
				let copy = directory.appending(path: url.lastPathComponent)
				do {
					try FileManager.default.copyItem(at: url, to: copy)
					continuation.resume(returning: copy)
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}
}
