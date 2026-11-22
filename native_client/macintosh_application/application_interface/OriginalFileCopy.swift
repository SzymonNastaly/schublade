import Foundation

/// Writes a copy of a cached original where a person puts it, by Export or by dragging it out. The
/// cache keeps its originals read-only, and a copy would keep that mode, so a person could not
/// annotate or replace the file they took; the copy is theirs, readable and writable.
enum OriginalFileCopy {
	nonisolated static func write(from source: URL, to destination: URL) throws {
		let files = FileManager.default
		if files.fileExists(atPath: destination.path(percentEncoded: false)) {
			try files.removeItem(at: destination)
		}
		try files.copyItem(at: source, to: destination)
		try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path(percentEncoded: false))
	}
}
