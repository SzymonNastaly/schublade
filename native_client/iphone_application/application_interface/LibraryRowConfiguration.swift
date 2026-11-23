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
		var shown = DocumentRowPresentation.from(row, context: context)
		if setting == .browsing(underMonth: true) {
			shown.dateText = row.documentDate.map { DocumentFormatting.dayAndMonth($0, context: context) }
		}
		if case .browsing = setting, case .archived = row.condition {
			shown.thirdLineText = ""
		}
		// Only a passage of the text is an excerpt, whose matched words are marked.
		let marked: String? = if case let .searching(text) = setting, case .excerpt = row.passage {
			text
		} else {
			nil
		}
		let identity = "document.\(row.document.value)"
		let content = DocumentRowContent(
			identity: identity,
			document: row.document,
			row: shown,
			picture: picture,
			trailing: .absent,
			spokenValue: nil,
			updatesFrequently: false,
			markedSearch: marked
		)
		cell.contentConfiguration = content
		content.describe(cell)
		cell.accessories = []
		cell.accessibilityIdentifier = identity
		cell.accessibilityHint = nil
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
		cell.accessibilityHint = nil
	}

	/// A scope the search offers: its symbol in the tint, its name, and its kind with its count.
	static func configure(_ cell: UICollectionViewListCell, suggestion: ScopeSuggestion) {
		var content = UIListContentConfiguration.subtitleCell()
		content.image = UIImage(systemName: suggestion.symbol)
		content.imageProperties.tintColor = .tintColor
		content.text = suggestion.scope.name
		content.secondaryText = "\(suggestion.kind) · "
			+ DocumentFormatting.countText(suggestion.documents, singular: "document")
		content.secondaryTextProperties.color = .secondaryLabel
		cell.contentConfiguration = content
		cell.accessories = []
		cell.isAccessibilityElement = true
		cell.accessibilityLabel = suggestion.scope.name
		cell.accessibilityValue = content.secondaryText
		cell.accessibilityHint = "Shows the documents of \(suggestion.scope.name)"
		cell.accessibilityTraits = [.button]
		cell.accessibilityIdentifier = "library.suggestion"
	}

	/// A connection that needs the person, with a disclosure indicator where a new token is the way out.
	static func configure(_ cell: UICollectionViewListCell, attention: ConnectionAttention) {
		var content = UIListContentConfiguration.subtitleCell()
		content.image = UIImage(systemName: "exclamationmark.triangle.fill")
		content.imageProperties.tintColor = InterfacePalette.attentionText
		content.text = attention.title
		content.textProperties.font = .preferredFont(forTextStyle: .headline)
		content.secondaryText = attention.detail
		content.secondaryTextProperties.color = .secondaryLabel
		content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
		content.textToSecondaryTextVerticalPadding = 3
		cell.contentConfiguration = content
		cell.accessories = attention.replacesToken ? [.disclosureIndicator()] : []
		cell.isAccessibilityElement = true
		cell.accessibilityLabel = attention.title
		cell.accessibilityValue = attention.detail
		cell.accessibilityTraits = attention.replacesToken ? [.button] : [.staticText]
		cell.accessibilityIdentifier = "library.attention"
		cell.accessibilityHint = nil
	}

	static func configure(_ cell: UICollectionViewListCell, notice: UIContentUnavailableConfiguration?) {
		cell.contentConfiguration = notice
		cell.accessories = []
		cell.isAccessibilityElement = false
		cell.accessibilityLabel = nil
		cell.accessibilityValue = nil
		cell.accessibilityIdentifier = nil
		cell.accessibilityHint = nil
	}
}
