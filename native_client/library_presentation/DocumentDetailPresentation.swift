import ApplicationBindings
import Foundation

/// Presentation model for the reader header and document inspector pane.
public struct DocumentDetailPresentation: Equatable, Sendable {
	private static let knownFieldLabels: [String: String] = [
		"amount": "Amount",
		"currency": "Currency",
		"due_date": "Due",
		"iban": "IBAN",
		"customer_number": "Customer",
		"invoice_number": "Invoice",
		"policy_number": "Policy",
		"renewal_date": "Renewal",
		"cancellation_period": "Notice Period",
	]

	public let title: String
	public let headerSubtitle: String
	public let detailRows: [InspectorDetailRow]
	public let tags: [NamedScope]
	public let summary: String?
	public let fileFacts: [InspectorFileFact]
	public let archivePageURL: URL?
	public let originalKind: OriginalKind
	public let suggestedFileName: String

	public init(
		title: String,
		headerSubtitle: String,
		detailRows: [InspectorDetailRow],
		tags: [NamedScope],
		summary: String?,
		fileFacts: [InspectorFileFact],
		archivePageURL: URL?,
		originalKind: OriginalKind,
		suggestedFileName: String
	) {
		self.title = title
		self.headerSubtitle = headerSubtitle
		self.detailRows = detailRows
		self.tags = tags
		self.summary = summary
		self.fileFacts = fileFacts
		self.archivePageURL = archivePageURL
		self.originalKind = originalKind
		self.suggestedFileName = suggestedFileName
	}

	public static func from(_ detail: DocumentDetail, context: WordingContext) -> DocumentDetailPresentation {
		let title = DocumentRowPresentation.displayTitle(detail.title, condition: detail.condition)
		let headerSubtitle = buildHeaderSubtitle(detail: detail, context: context)
		let detailRows = buildDetailRows(detail: detail, context: context)
		let fileFacts = buildFileFacts(detail: detail, context: context)
		let summary = detail.summary.flatMap { $0.isEmpty ? nil : $0 }

		return DocumentDetailPresentation(
			title: title,
			headerSubtitle: headerSubtitle,
			detailRows: detailRows,
			tags: detail.tags,
			summary: summary,
			fileFacts: fileFacts,
			archivePageURL: URL(string: detail.archivePage),
			originalKind: detail.originalKind,
			suggestedFileName: detail.suggestedFileName
		)
	}

	/// "Nordbank AG · 22 Sep 2026", without the page count, which the header adds.
	public static func senderAndDate(of detail: DocumentDetail, context: WordingContext) -> String {
		senderAndDateParts(of: detail, context: context).joined(separator: " · ")
	}

	private static func senderAndDateParts(of detail: DocumentDetail, context: WordingContext) -> [String] {
		var parts: [String] = []
		if let sender = detail.sender, !sender.name.isEmpty {
			parts.append(sender.name)
		}
		if let date = detail.documentDate {
			parts.append(DocumentFormatting.calendarDate(date, context: context))
		}
		return parts
	}

	private static func buildHeaderSubtitle(detail: DocumentDetail, context: WordingContext) -> String {
		var parts = senderAndDateParts(of: detail, context: context)
		if let pages = detail.pageCount, pages > 0 {
			parts.append(DocumentFormatting.countText(UInt64(pages), singular: "page"))
		}
		return parts.joined(separator: " · ")
	}

	private static func buildDetailRows(detail: DocumentDetail, context: WordingContext) -> [InspectorDetailRow] {
		var rows: [InspectorDetailRow] = []
		if let sender = detail.sender {
			rows.append(InspectorDetailRow(
				label: "Sender",
				displayValue: sender.name,
				copyValue: sender.name,
				linkedScope: sender
			))
		}
		if let category = detail.category {
			rows.append(InspectorDetailRow(
				label: "Category",
				displayValue: category.name,
				copyValue: category.name,
				linkedScope: category
			))
		}
		if let person = detail.person {
			let scope = personScope(person)
			rows.append(InspectorDetailRow(
				label: "Person",
				displayValue: scope.name,
				copyValue: scope.name,
				linkedScope: scope
			))
		}
		if let date = detail.documentDate {
			rows.append(InspectorDetailRow(
				label: "Date",
				displayValue: DocumentFormatting.calendarDate(date, context: context),
				copyValue: DocumentFormatting.isoDate(date),
				linkedScope: nil
			))
		}
		rows.append(contentsOf: extractedFieldRows(fields: detail.fields, context: context))
		return rows
	}

	private static func personScope(_ person: DocumentPerson) -> NamedScope {
		switch person {
		case .household:
			NamedScope(scope: .household, name: "Household")
		case let .member(scope):
			scope
		}
	}

	private static func extractedFieldRows(
		fields: [DetailField],
		context: WordingContext
	) -> [InspectorDetailRow] {
		let hasNumberAmount = fields.contains { field in
			field.key == "amount" && isNumberField(field.value)
		}

		return fields.compactMap { field in
			if field.key == "currency", hasNumberAmount {
				return nil
			}
			let label = labelForFieldKey(field.key)
			if field.key == "amount", case let .number(decimalText) = field.value {
				let currency = DocumentFormatting.currency(in: fields)
				return InspectorDetailRow(
					label: label,
					displayValue: DocumentFormatting.decimalAmount(decimalText, currency: currency),
					copyValue: decimalText,
					linkedScope: nil
				)
			}
			return formatExtractedField(key: field.key, label: label, value: field.value, context: context)
		}
	}

	private static func formatExtractedField(
		key: String,
		label: String,
		value: FieldValue,
		context: WordingContext
	) -> InspectorDetailRow {
		switch value {
		case let .text(text):
			if key == "iban" {
				return InspectorDetailRow(
					label: label,
					displayValue: DocumentFormatting.formattedIban(text),
					copyValue: DocumentFormatting.plainIban(text),
					linkedScope: nil
				)
			}
			if key == "cancellation_period" {
				return InspectorDetailRow(
					label: label,
					displayValue: DocumentFormatting.formattedPeriod(text),
					copyValue: text,
					linkedScope: nil
				)
			}
			return InspectorDetailRow(label: label, displayValue: text, copyValue: text, linkedScope: nil)
		case let .number(decimalText):
			return InspectorDetailRow(
				label: label,
				displayValue: DocumentFormatting.decimalAmount(decimalText),
				copyValue: decimalText,
				linkedScope: nil
			)
		case let .date(date):
			return InspectorDetailRow(
				label: label,
				displayValue: DocumentFormatting.calendarDate(date, context: context),
				copyValue: DocumentFormatting.isoDate(date),
				linkedScope: nil
			)
		}
	}

	private static func isNumberField(_ value: FieldValue) -> Bool {
		if case .number = value {
			return true
		}
		return false
	}

	private static func labelForFieldKey(_ key: String) -> String {
		if let known = knownFieldLabels[key] {
			return known
		}
		return key
			.split(separator: "_")
			.map { word in
				word.prefix(1).uppercased() + word.dropFirst()
			}
			.joined(separator: " ")
	}

	private static func buildFileFacts(detail: DocumentDetail, context: WordingContext) -> [InspectorFileFact] {
		var facts = [
			InspectorFileFact(label: "Kind", value: kindLabel(detail.originalKind)),
		]
		if let pages = detail.pageCount, pages > 0 {
			facts.append(InspectorFileFact(label: "Pages", value: DocumentFormatting.groupedNumber(UInt64(pages))))
		}
		facts.append(InspectorFileFact(label: "Size", value: DocumentFormatting.byteSize(detail.byteSize)))
		facts.append(InspectorFileFact(
			label: "Added",
			value: DocumentFormatting.dayOfTimestamp(detail.arrivedAt, context: context)
		))
		return facts
	}

	private static func kindLabel(_ kind: OriginalKind) -> String {
		switch kind {
		case .portableDocument:
			"PDF Document"
		case .jpegImage:
			"JPEG Image"
		case .pngImage:
			"PNG Image"
		case .webpImage:
			"WebP Image"
		case .unprintedEmail:
			"Unprinted Email"
		case .unrecognized:
			"Document"
		}
	}
}
