import Foundation
import ImageIO
import SubmissionQueue
import UniformTypeIdentifiers

/// A file a person chose in Photos or Files, made into something the archive accepts: a PDF, JPEG,
/// PNG, or WebP stays as it is, and any other picture, such as the HEIC of the iPhone's camera,
/// becomes a JPEG.
nonisolated enum DocumentImport {
	struct ImportedDocument {
		let file: URL
		let fileName: String
		let kind: SubmissionFileKind
	}

	enum ImportFailure: Error, Equatable {
		case unacceptedKind(String)
		case unreadable(String)
	}

	/// Converts `file`, which the caller owns, into an importable document in its own directory.
	static func prepare(file: URL, suggestedName: String?) throws(ImportFailure) -> ImportedDocument {
		let type = (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType
			?? UTType(filenameExtension: file.pathExtension)
		let baseName = (suggestedName ?? file.deletingPathExtension().lastPathComponent)
			.replacingOccurrences(of: "/", with: "-")
		let accepted: [(UTType, SubmissionFileKind)] = [(.pdf, .pdf), (.jpeg, .jpeg), (.png, .png), (.webP, .webp)]
		if let type, let kind = accepted.first(where: { type.conforms(to: $0.0) })?.1 {
			return ImportedDocument(file: file, fileName: "\(baseName).\(kind.fileExtension)", kind: kind)
		}
		guard let type, type.conforms(to: .image) else {
			throw .unacceptedKind(file.lastPathComponent)
		}
		let converted = file.deletingLastPathComponent().appending(path: "\(UUID().uuidString).jpg")
		guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
		      let destination = CGImageDestinationCreateWithURL(
		      	converted as CFURL,
		      	UTType.jpeg.identifier as CFString,
		      	1,
		      	nil
		      )
		else {
			throw .unreadable(file.lastPathComponent)
		}
		let options = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
		CGImageDestinationAddImageFromSource(destination, source, 0, options)
		guard CGImageDestinationFinalize(destination) else {
			throw .unreadable(file.lastPathComponent)
		}
		try? FileManager.default.removeItem(at: file)
		return ImportedDocument(file: converted, fileName: "\(baseName).jpg", kind: .jpeg)
	}

	/// A new directory of the temporary directory, for a copy the application owns.
	static func workingDirectory() throws(ImportFailure) -> URL {
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
