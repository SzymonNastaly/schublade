import DocumentReading
import Foundation

/// How a person chose a document to send.
public enum SubmissionOrigin: String, Codable, Sendable {
	case scan
	case importedPhoto
	case importedFile
	case share
}

/// The kinds of file the archive accepts.
public enum SubmissionFileKind: String, Codable, Sendable {
	case pdf
	case jpeg
	case png
	case webp

	public var fileExtension: String {
		switch self {
		case .pdf: "pdf"
		case .jpeg: "jpg"
		case .png: "png"
		case .webp: "webp"
		}
	}

	/// Reads what the archive receives beside a file of this kind, from the file mapped rather than
	/// copied, so the share extension holds only the pages it draws. Nil when the file cannot be read.
	public func contents(of file: URL, recognizing: Bool) -> DocumentContents? {
		guard let original = try? Data(contentsOf: file, options: .alwaysMapped) else {
			return nil
		}
		return DocumentContents.read(original, kind: self == .pdf ? .pdf : .picture, recognizing: recognizing)
	}
}

/// What a submission is, written once into `submission.json` when the submission is created.
public struct SubmissionManifest: Codable, Equatable, Sendable {
	public let identifier: UUID
	public let origin: SubmissionOrigin
	/// The name the archive receives, such as "Scan 2026-11-22 21.30.pdf".
	public let fileName: String
	public let kind: SubmissionFileKind
	public let byteCount: UInt64
	/// The pages of a scan, nil for anything else.
	public let pageCount: Int?
	public let createdAt: Date
	/// When the share extension claimed the upload, which it starts right after creating the
	/// submission. Nil for a submission the application sends.
	public let uploadClaimedAt: Date?
}
