import ApplicationBindings
import LibraryPresentation
import SubmissionQueue
import UIKit

/// How a row of the library screen draws a document and a submission, with the system's list cell
/// and the wording the Mac shares.
enum LibraryRowConfiguration {
	static func configure(
		_ cell: UICollectionViewListCell,
		document row: DocumentRow,
		picture: UIImage?,
		context: WordingContext
	) {
		cell.contentConfiguration = DocumentRowContent(
			row: DocumentRowPresentation.from(row, context: context),
			picture: picture
		)
		cell.accessories = []
		cell.accessibilityIdentifier = "document.\(row.document.value)"
	}

	static func configure(_ cell: UICollectionViewListCell, submission entry: SubmissionEntry, sentFraction: Double?) {
		let row = SubmissionRowWording.row(entry, sentFraction: sentFraction)
		var content = UIListContentConfiguration.subtitleCell()
		content.text = row.title
		content.textProperties.font = .preferredFont(forTextStyle: .headline)
		content.secondaryText = row.status
		content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
		content.secondaryTextProperties.color = .secondaryLabel
		content.textToSecondaryTextVerticalPadding = 4
		content.image = UIImage(systemName: row.symbol)
		content.imageProperties.reservedLayoutSize = DocumentRowContent.pictureSize
		content.imageProperties.tintColor = switch row.tone {
		case .waiting: .secondaryLabel
		case .archived: InterfacePalette.archive
		case .attention: InterfacePalette.attention
		}
		content.imageToTextPadding = 14
		content.directionalLayoutMargins.top = 12
		content.directionalLayoutMargins.bottom = 12
		cell.contentConfiguration = content
		if case .archived = entry.answer {
			cell.accessories = [.disclosureIndicator()]
		} else {
			cell.accessories = []
		}
	}
}
