import ApplicationBindings
import Foundation

/// How a person chose a document to send.
public enum SubmissionOrigin: String, Codable, Sendable {
	case scan
	case importedPhoto
	case importedFile
	case share
}

/// The kinds of file the archive accepts, as the bindings' `DocumentMediaType` names them.
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

	public var mediaType: DocumentMediaType {
		switch self {
		case .pdf: .pdf
		case .jpeg: .jpeg
		case .png: .png
		case .webp: .webp
		}
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
}
