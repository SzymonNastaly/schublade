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

	/// Of the types a shared item offers, the one to load: a kind the archive takes as it is, else a
	/// picture to convert, else nil for an item the archive does not take.
	public static func preferredType(among offered: [UTType]) -> UTType? {
		offered.first { type in acceptedKinds.contains { type.conforms(to: $0.0) } }
			?? offered.first { $0.conforms(to: .image) }
	}

	/// Converts `file`, which the caller owns, into an importable document in its own directory.
	/// `type` is the type the file was loaded as, because a shared copy may carry no extension.
	public static func prepare(
		file: URL,
		type: UTType,
		suggestedName: String?
	) throws(ImportFailure) -> ImportedDocument {
		let name = nameWithoutRecognizedExtension(suggestedName ?? file.lastPathComponent)
		if let kind = acceptedKinds.first(where: { type.conforms(to: $0.0) })?.1 {
			return ImportedDocument(file: file, fileName: "\(name).\(kind.fileExtension)", kind: kind)
		}
		guard type.conforms(to: .image) else {
			throw .unacceptedKind(file.lastPathComponent)
		}
		let converted = file.deletingLastPathComponent().appending(path: "\(UUID().uuidString).jpg")
		// The decoded picture is released before the next file, because a share extension is ended
		// above about 120 MB.
		let written = autoreleasepool {
			let hint = [kCGImageSourceTypeIdentifierHint: type.identifier] as CFDictionary
			guard let source = CGImageSourceCreateWithURL(file as CFURL, hint),
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
		return ImportedDocument(file: converted, fileName: "\(name).jpg", kind: .jpeg)
	}

	/// A name without the extension it may carry, as Safari's suggested names do, because the
	/// extension of the kind sent follows it. Only an extension that names a type goes, so
	/// "Invoice 10.2026" keeps its ".2026".
	private static func nameWithoutRecognizedExtension(_ name: String) -> String {
		let named = URL(filePath: name.replacingOccurrences(of: "/", with: "-"))
		guard let namedType = UTType(filenameExtension: named.pathExtension), !namedType.isDynamic else {
			return named.lastPathComponent
		}
		return named.deletingPathExtension().lastPathComponent
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
