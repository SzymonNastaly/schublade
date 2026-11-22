import ApplicationBindings

/// Ready-to-render fields for one document row cell.
public struct DocumentRowPresentation: Equatable, Sendable {
	public let title: String
	public let sender: String
	public let dateText: String?
	public let amountText: String?
	public let thirdLineText: String
	public let thirdLineTone: DocumentRowThirdLineTone
	public let contentKnown: Bool

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
		let displayTitle: String = if let title = row.title, !title.isEmpty {
			title
		} else {
			switch row.condition {
			case .inIngestion:
				"Processing Document"
			case .archived, .failed:
				"Untitled Document"
			}
		}

		let dateText = row.documentDate.map { DocumentFormatting.calendarDate($0, context: context) }
		let amountText = row.amount.map(DocumentFormatting.amount)

		let thirdLineText: String
		let thirdLineTone: DocumentRowThirdLineTone
		switch row.condition {
		case let .inIngestion(stage):
			thirdLineText = ApplicationFailureWording.stageText(stage)
			thirdLineTone = .accent
		case let .failed(reason):
			thirdLineText = ApplicationFailureWording.failureText(reason)
			thirdLineTone = .failure
		case .archived:
			thirdLineTone = .secondary
			switch row.passage {
			case let .summary(text), let .excerpt(text):
				thirdLineText = text
			case nil:
				thirdLineText = ""
			}
		}

		return DocumentRowPresentation(
			title: displayTitle,
			sender: row.senderName ?? "",
			dateText: dateText,
			amountText: amountText,
			thirdLineText: thirdLineText,
			thirdLineTone: thirdLineTone,
			contentKnown: row.contentKnown
		)
	}
}
