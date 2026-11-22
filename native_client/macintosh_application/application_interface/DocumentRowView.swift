import AppKit
import ApplicationBindings

/// Plain three-line document row cell for `DocumentListViewController`.
final class DocumentRowView: NSTableCellView {
	private let titleField = NSTextField(labelWithString: "")
	private let trailingField = NSTextField(labelWithString: "")
	private let senderField = NSTextField(labelWithString: "")
	private let detailField = NSTextField(labelWithString: "")

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		configureFields()
		configureLayout()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func configure(with row: DocumentRow) {
		titleField.stringValue = Self.displayTitle(for: row)
		trailingField.stringValue = Self.trailingText(for: row)
		senderField.stringValue = row.senderName ?? ""

		switch row.condition {
		case let .inIngestion(stage):
			detailField.stringValue = Self.stageText(stage)
			detailField.textColor = .controlAccentColor
		case let .failed(reason):
			detailField.stringValue = Self.failureText(reason)
			detailField.textColor = .systemRed
		case .archived:
			detailField.textColor = .secondaryLabelColor
			switch row.passage {
			case let .summary(text):
				detailField.stringValue = text
			case let .excerpt(text):
				detailField.stringValue = text
			case nil:
				detailField.stringValue = ""
			}
		}
	}

	private func configureFields() {
		titleField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		titleField.lineBreakMode = .byTruncatingTail
		titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		titleField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowTitle)

		trailingField.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
		trailingField.textColor = .secondaryLabelColor
		trailingField.setContentHuggingPriority(.required, for: .horizontal)
		trailingField.setContentCompressionResistancePriority(.required, for: .horizontal)

		senderField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		senderField.textColor = .secondaryLabelColor
		senderField.lineBreakMode = .byTruncatingTail
		senderField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowSender)

		detailField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		detailField.textColor = .secondaryLabelColor
		detailField.lineBreakMode = .byTruncatingTail
		detailField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowDetail)
	}

	private func configureLayout() {
		let topRow = NSStackView(views: [titleField, trailingField])
		topRow.orientation = .horizontal
		topRow.alignment = .firstBaseline
		topRow.spacing = 8

		let stack = NSStackView(views: [topRow, senderField, detailField])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 2
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)

		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
			senderField.widthAnchor.constraint(equalTo: stack.widthAnchor),
			detailField.widthAnchor.constraint(equalTo: stack.widthAnchor),
		])
	}

	private static func displayTitle(for row: DocumentRow) -> String {
		if let title = row.title, !title.isEmpty {
			return title
		}
		switch row.condition {
		case .inIngestion:
			return "Processing Document"
		case .archived, .failed:
			return "Untitled Document"
		}
	}

	private static func trailingText(for row: DocumentRow) -> String {
		var parts: [String] = []
		if let date = row.documentDate {
			parts.append(String(format: "%04u-%02u-%02u", UInt32(date.year), UInt32(date.month), UInt32(date.day)))
		}
		if let amount = row.amount {
			if let currency = amount.currency, !currency.isEmpty {
				parts.append("\(amount.decimalText) \(currency)")
			} else {
				parts.append(amount.decimalText)
			}
		}
		return parts.joined(separator: " · ")
	}

	private static func stageText(_ stage: IngestionStage) -> String {
		switch stage {
		case .awaitingRendering: "Waiting to print email"
		case .processing: "Queued for processing"
		case .extracting: "Extracting text"
		case .recognizingText: "Recognizing text"
		case .classifying: "Classifying document"
		case .other: "Processing document"
		}
	}

	private static func failureText(_ reason: FailureReason) -> String {
		switch reason {
		case .unreadableFile: "Could not read this file"
		case .pageLimitExceeded: "Exceeds page limit"
		case .unreadablePage: "Could not read a page"
		case .processingError: "Processing failed"
		case .other: "Ingestion failed"
		}
	}
}
