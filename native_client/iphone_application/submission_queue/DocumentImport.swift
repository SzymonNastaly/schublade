import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file a person chose in Photos or Files or shared from another application, made into
/// something the archive accepts: a PDF, JPEG, PNG, or WebP stays as it is, and any other picture,
/// such as the HEIC of the iPhone's camera, becomes a JPEG.
public enum DocumentImport {
	public struct ImportedDocument: Sendable {
		public let file: URL
		public let fileName: String
		public let kind: SubmissionFileKind
	}

	public enum ImportFailure: Error, Equatable {
		case unacceptedKind(String)
		case unreadable(String)
	}

	private static let acceptedKinds: [(UTType, SubmissionFileKind)] = [
		(.pdf, .pdf),
		(.jpeg, .jpeg),
		(.png, .png),
		(.webP, .webp),
	]

	/// Whether a file of `type` can be sent, as it is or as a JPEG.
	public static func accepts(_ type: UTType) -> Bool {
		type.conforms(to: .pdf) || type.conforms(to: .image)
	}

	/// Converts `file`, which the caller owns, into an importable document in its own directory.
	public static func prepare(file: URL, suggestedName: String?) throws(ImportFailure) -> ImportedDocument {
		let type = (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType
			?? UTType(filenameExtension: file.pathExtension)
		let baseName = (suggestedName ?? file.deletingPathExtension().lastPathComponent)
			.replacingOccurrences(of: "/", with: "-")
		if let type, let kind = acceptedKinds.first(where: { type.conforms(to: $0.0) })?.1 {
			return ImportedDocument(file: file, fileName: "\(baseName).\(kind.fileExtension)", kind: kind)
		}
		guard let type, accepts(type) else {
			throw .unacceptedKind(file.lastPathComponent)
		}
		let converted = file.deletingLastPathComponent().appending(path: "\(UUID().uuidString).jpg")
		// The decoded picture is released before the next file, because a share extension is ended
		// above about 120 MB.
		let written = autoreleasepool {
			guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
			      let destination = CGImageDestinationCreateWithURL(
			      	converted as CFURL,
			      	UTType.jpeg.identifier as CFString,
			      	1,
			      	nil
			      )
			else {
				return false
			}
			let options = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
			CGImageDestinationAddImageFromSource(destination, source, 0, options)
			return CGImageDestinationFinalize(destination)
		}
		guard written else {
			throw .unreadable(file.lastPathComponent)
		}
		try? FileManager.default.removeItem(at: file)
		return ImportedDocument(file: converted, fileName: "\(baseName).jpg", kind: .jpeg)
	}

	/// A new directory of the temporary directory, for a copy the process owns.
	public static func workingDirectory() throws(ImportFailure) -> URL {
		let directory = URL.temporaryDirectory.appending(
			path: "imports/\(UUID().uuidString)",
			directoryHint: .isDirectory
		)
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		} catch {
			throw .unreadable(error.localizedDescription)
		}
		return directory
	}
}
