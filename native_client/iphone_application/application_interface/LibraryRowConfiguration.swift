import ApplicationBindings
import LibraryPresentation
import UIKit

/// Where a document's row shows.
enum DocumentRowSetting: Equatable {
	case browsing(underMonth: Bool)
	/// The text the person searches for.
	case searching(String)
}

/// The cell of each kind of library row. Every kind sets the accessibility identifier, because a
/// reused cell would otherwise keep the one of the row it showed before.
enum LibraryRowConfiguration {
	/// While a person browses, an archived document's summary repeats its title, so its row has no
	/// third line. A search shows the passage that matched. Under a month's heading the date leaves
	/// the year to the heading.
	static func configure(
		_ cell: UICollectionViewListCell,
		document row: DocumentRow,
		picture: UIImage?,
		setting: DocumentRowSetting,
		context: WordingContext
	) {
		let presented = DocumentRowPresentation.from(row, context: context)
		let underMonth = setting == .browsing(underMonth: true)
		let browsingArchived = if case .browsing = setting, case .archived = row.condition {
			true
		} else {
			false
		}
		let shown = DocumentRowPresentation(
			title: presented.title,
			sender: presented.sender,
			dateText: underMonth
				? row.documentDate.map { DocumentFormatting.dayAndMonth($0, context: context) }
				: presented.dateText,
			amountText: presented.amountText,
			thirdLineText: browsingArchived ? "" : presented.thirdLineText,
			thirdLineTone: presented.thirdLineTone,
			contentKnown: presented.contentKnown
		)
		let identity = "document.\(row.document.value)"
		let content = DocumentRowContent(
			identity: identity,
			row: shown,
			picture: picture,
			trailing: .absent,
			spokenValue: nil,
			updatesFrequently: false
		)
		cell.contentConfiguration = content
		content.describe(cell)
		cell.accessories = []
		cell.accessibilityIdentifier = identity
	}

	static func configure(
		_ cell: UICollectionViewListCell,
		arrival: Arrival,
		picture: UIImage?,
		context: WordingContext
	) {
		let identity = "arrival.\(arrival.id.uuidString)"
		let content = DocumentRowContent(
			identity: identity,
			row: ArrivalPresentation.row(arrival, context: context),
			picture: picture,
			trailing: ArrivalPresentation.trailing(arrival.stage),
			spokenValue: ArrivalPresentation.spokenStage(arrival, context: context),
			updatesFrequently: true
		)
		cell.contentConfiguration = content
		content.describe(cell)
		cell.accessories = []
		cell.accessibilityIdentifier = identity
	}

	static func configure(_ cell: UICollectionViewListCell, notice: UIContentUnavailableConfiguration?) {
		cell.contentConfiguration = notice
		cell.accessories = []
		cell.isAccessibilityElement = false
		cell.accessibilityLabel = nil
		cell.accessibilityValue = nil
		cell.accessibilityIdentifier = nil
	}
}
