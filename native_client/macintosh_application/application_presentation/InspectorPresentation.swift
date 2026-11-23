import ApplicationBindings
import Foundation
import LibraryPresentation

/// The inspector of the Mac: the title once, the facts a person copies, the places the document is
/// filed under, its tags, and the file. A row that leads to a scope is filed under it, and every
/// other row is a fact.
public struct InspectorPresentation: Equatable, Sendable {
	public let title: String
	public let summary: String?
	/// "2 pages · PDF".
	public let fileLine: String
	public let facts: [InspectorDetailRow]
	public let filedUnder: [InspectorDetailRow]
	public let tags: [NamedScope]
	public let fileFacts: [InspectorFileFact]
	public let archivePageURL: URL?

	public static let browserSentence = "Edit the details, retry, or delete this document in your archive in the browser."

	public static func from(_ detail: DocumentDetail, context: WordingContext) -> InspectorPresentation {
		let presented = DocumentDetailPresentation.from(detail, context: context)
		var fileLine: [String] = []
		if let pages = detail.pageCount, pages > 0 {
			fileLine.append(DocumentFormatting.countText(UInt64(pages), singular: "page"))
		}
		fileLine.append(kindName(detail.originalKind))
		return InspectorPresentation(
			title: presented.title,
			summary: presented.summary,
			fileLine: fileLine.joined(separator: " · "),
			facts: presented.detailRows.filter { $0.linkedScope == nil },
			filedUnder: presented.detailRows.filter { $0.linkedScope != nil },
			tags: presented.tags,
			fileFacts: [
				InspectorFileFact(label: "Size", value: DocumentFormatting.byteSize(detail.byteSize)),
				InspectorFileFact(
					label: "Added",
					value: DocumentFormatting.dayOfTimestamp(detail.arrivedAt, context: context)
				),
			],
			archivePageURL: presented.archivePageURL
		)
	}

	private static func kindName(_ kind: OriginalKind) -> String {
		switch kind {
		case .portableDocument: "PDF"
		case .jpegImage: "JPEG"
		case .pngImage: "PNG"
		case .webpImage: "WebP"
		case .unprintedEmail: "Email"
		case .unrecognized: "Document"
		}
	}
}
