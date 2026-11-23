import ApplicationBindings

/// Ready-to-render fields for one document row cell.
public struct DocumentRowPresentation: Equatable, Sendable {
	public var title: String
	public var sender: String
	public var dateText: String?
	public var amountText: String?
	public var thirdLineText: String
	public var thirdLineTone: DocumentRowThirdLineTone
	public var contentKnown: Bool

	public init(
		title: String,
		sender: String,
		dateText: String?,
		amountText: String?,
		thirdLineText: String,
		thirdLineTone: DocumentRowThirdLineTone,
		contentKnown: Bool
	) {
		self.title = title
		self.sender = sender
		self.dateText = dateText
		self.amountText = amountText
		self.thirdLineText = thirdLineText
		self.thirdLineTone = thirdLineTone
		self.contentKnown = contentKnown
	}

	public static func from(_ row: DocumentRow, context: WordingContext) -> DocumentRowPresentation {
		let passage: String? = switch row.passage {
		case let .summary(text), let .excerpt(text): text
		case nil: nil
		}
		let (thirdLineText, thirdLineTone) = thirdLine(row.condition, passage: passage)
		return DocumentRowPresentation(
			title: displayTitle(row.title, condition: row.condition),
			sender: row.senderName ?? "",
			dateText: row.documentDate.map { DocumentFormatting.calendarDate($0, context: context) },
			amountText: row.amount.map(DocumentFormatting.amount),
			thirdLineText: thirdLineText,
			thirdLineTone: thirdLineTone,
			contentKnown: row.contentKnown
		)
	}

	/// The row of a document the copy holds in full, for a row that shows it before the listing does.
	/// A detail does not say whether the archive recorded the document's content, so the row does not
	/// claim it.
	public static func from(_ detail: DocumentDetail, context: WordingContext) -> DocumentRowPresentation {
		let (thirdLineText, thirdLineTone) = thirdLine(detail.condition, passage: detail.summary)
		return DocumentRowPresentation(
			title: displayTitle(detail.title, condition: detail.condition),
			sender: detail.sender?.name ?? "",
			dateText: detail.documentDate.map { DocumentFormatting.calendarDate($0, context: context) },
			amountText: DocumentFormatting.amountText(in: detail.fields),
			thirdLineText: thirdLineText,
			thirdLineTone: thirdLineTone,
			contentKnown: false
		)
	}

	/// A document's title, or what stands in for a title the archive has not given it.
	static func displayTitle(_ title: String?, condition: DocumentCondition) -> String {
		if let title, !title.isEmpty {
			return title
		}
		switch condition {
		case .inIngestion:
			return "Processing Document"
		case .archived, .failed:
			return "Untitled Document"
		}
	}

	/// An archived document shows its passage, one in ingestion its stage, and a failed one why.
	private static func thirdLine(
		_ condition: DocumentCondition,
		passage: String?
	) -> (String, DocumentRowThirdLineTone) {
		switch condition {
		case let .inIngestion(stage): (LibraryFailureWording.stageText(stage), .accent)
		case let .failed(reason): (LibraryFailureWording.failureText(reason), .failure)
		case .archived: (passage ?? "", .secondary)
		}
	}
}
