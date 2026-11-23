import ApplicationBindings
import LibraryPresentation
import UIKit

/// One section of the details sheet.
struct DocumentDetailSection {
	let header: String?
	let footer: String?
	let rows: [DocumentDetailRow]

	/// The head with the title and summary, the facts, what the document is filed under, its tags,
	/// and its file with the ways to the text and to the archive in the browser.
	static func sections(of detail: DocumentDetailPresentation) -> [DocumentDetailSection] {
		let head = DocumentDetailRow.head(title: detail.title, summary: detail.summary)
		var sections = [DocumentDetailSection(header: nil, footer: nil, rows: [head])]
		let facts = detail.detailRows.filter { $0.linkedScope == nil }
		if !facts.isEmpty {
			sections.append(DocumentDetailSection(header: nil, footer: nil, rows: facts.map(DocumentDetailRow.fact)))
		}
		let filed = detail.detailRows.compactMap { row in row.linkedScope.map { DocumentDetailRow.filed(row, $0) } }
		if !filed.isEmpty {
			sections.append(DocumentDetailSection(header: "Filed Under", footer: nil, rows: filed))
		}
		if !detail.tags.isEmpty {
			sections.append(DocumentDetailSection(
				header: "Tags",
				footer: nil,
				rows: detail.tags.map(DocumentDetailRow.tag)
			))
		}
		var file = detail.fileFacts.map(DocumentDetailRow.fileFact) + [.extractedText]
		if let page = detail.archivePageURL {
			file.append(.openInBrowser(page))
		}
		sections.append(DocumentDetailSection(
			header: "File",
			footer: "Edit the details, retry, or delete this document in your archive in the browser.",
			rows: file
		))
		return sections
	}
}

/// One row of the details sheet, and how its cell draws it.
enum DocumentDetailRow: Equatable {
	case head(title: String, summary: String?)
	/// A value a tap copies, such as the amount or the IBAN.
	case fact(InspectorDetailRow)
	/// The sender, the category, or the person, whose documents a tap shows.
	case filed(InspectorDetailRow, NamedScope)
	case tag(NamedScope)
	case fileFact(InspectorFileFact)
	case extractedText
	case openInBrowser(URL)

	/// What the touch-and-hold menu copies, nil for a row that holds no value.
	var copyValue: String? {
		switch self {
		case let .head(title, _): title
		case let .fact(row), let .filed(row, _): row.copyValue ?? row.displayValue
		case let .tag(scope): scope.name
		case let .fileFact(fact): fact.value
		case .extractedText, .openInBrowser: nil
		}
	}

	/// `copied` shows a fact's value as "Copied", for the second after its tap.
	func configure(_ cell: UICollectionViewListCell, copied: Bool) {
		cell.accessories = []
		cell.backgroundConfiguration = nil
		cell.accessibilityTraits = []
		cell.accessibilityHint = nil
		cell.accessibilityIdentifier = nil
		switch self {
		case let .head(title, summary):
			cell.contentConfiguration = Self.headContent(title: title, summary: summary)
			cell.backgroundConfiguration = .clear()
		case let .fact(fact):
			Self.configureFact(cell, fact: fact, copied: copied)
		case let .filed(row, scope):
			cell.contentConfiguration = Self.valueContent(label: row.label, value: row.displayValue)
			cell.accessories = [.disclosureIndicator()]
			cell.accessibilityHint = "Shows the documents of \(scope.name)."
		case let .tag(scope):
			var content = UIListContentConfiguration.cell()
			content.text = scope.name
			cell.contentConfiguration = content
			cell.accessories = [.disclosureIndicator()]
			cell.accessibilityHint = "Shows the documents of \(scope.name)."
		case let .fileFact(fact):
			cell.contentConfiguration = Self.valueContent(label: fact.label, value: fact.value)
		case .extractedText:
			var content = UIListContentConfiguration.cell()
			content.text = "Extracted Text"
			content.image = UIImage(systemName: "text.page")
			cell.contentConfiguration = content
			cell.accessories = [.disclosureIndicator()]
			cell.accessibilityHint = "Shows the text the archive read from this document."
			cell.accessibilityIdentifier = "document.details.extractedText"
		case .openInBrowser:
			var content = UIListContentConfiguration.cell()
			content.text = "Open in Browser"
			content.textProperties.color = .tintColor
			content.image = UIImage(systemName: "safari")
			cell.contentConfiguration = content
		}
	}

	/// The one full statement of the title on the page, which the navigation bar truncates.
	private static func headContent(title: String, summary: String?) -> UIListContentConfiguration {
		var content = UIListContentConfiguration.cell()
		content.text = title
		content.textProperties.font = UIFontMetrics(forTextStyle: .title3)
			.scaledFont(for: .systemFont(ofSize: 20, weight: .semibold))
		content.textProperties.numberOfLines = 0
		content.secondaryText = summary
		content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
		content.secondaryTextProperties.color = .secondaryLabel
		content.textToSecondaryTextVerticalPadding = 6
		content.directionalLayoutMargins.top = 0
		return content
	}

	private static func configureFact(_ cell: UICollectionViewListCell, fact: InspectorDetailRow, copied: Bool) {
		var content = valueContent(label: fact.label, value: copied ? "Copied" : fact.displayValue)
		// Amounts and IBANs are compared and copied digit by digit.
		content.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .body)
			.scaledFont(for: .monospacedDigitSystemFont(ofSize: 17, weight: .regular))
		if copied {
			content.secondaryTextProperties.color = .tintColor
		}
		cell.contentConfiguration = content
		let symbol = UIImageView(image: UIImage(
			systemName: copied ? "checkmark" : "doc.on.doc",
			withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote)
		))
		symbol.tintColor = copied ? .tintColor : .tertiaryLabel
		cell.accessories = [.customView(configuration: .init(customView: symbol, placement: .trailing()))]
		cell.accessibilityTraits = .button
		cell.accessibilityHint = "Copies the value."
	}

	/// A label in the secondary colour and its value in the label's colour, because the value is
	/// what a person reads.
	private static func valueContent(label: String, value: String) -> UIListContentConfiguration {
		var content = UIListContentConfiguration.valueCell()
		content.text = label
		content.textProperties.color = .secondaryLabel
		content.secondaryText = value
		content.secondaryTextProperties.color = .label
		return content
	}
}
