import ApplicationBindings
import Foundation
import LibraryPresentation
import Testing

struct DocumentPresentationTests {
	private static func fixedContext() -> WordingContext {
		var calendar = Calendar(identifier: .gregorian)
		if let universalTimeZone = TimeZone(secondsFromGMT: 0) {
			calendar.timeZone = universalTimeZone
		}
		return WordingContext(
			now: Date(timeIntervalSince1970: 1_790_000_000),
			calendar: calendar,
			locale: Locale(identifier: "en_GB")
		)
	}

	@Test func rowPresentationFormatsDateAmountAndConditionTones() {
		let context = Self.fixedContext()
		let archivedRow = DocumentRow(
			document: DocumentIdentifier(value: "d1"),
			condition: .archived,
			title: nil,
			senderName: "Stadtwerke Talbrück GmbH",
			documentDate: CalendarDate(year: 2026, month: 9, day: 22),
			arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
			amount: Amount(decimalText: "1234.5", currency: "EUR"),
			passage: .excerpt(text: "Haftpflichtversicherung Rechnung"),
			contentKnown: true,
			suggestedFileName: "document.pdf"
		)
		let archived = DocumentRowPresentation.from(archivedRow, context: context)
		#expect(archived.title == "Untitled Document")
		#expect(archived.dateText == "22 Sep 2026")
		#expect(archived.amountText == "1,234.50 EUR")
		#expect(archived.thirdLineText == "Haftpflichtversicherung Rechnung")
		#expect(archived.thirdLineTone == .secondary)

		let arrivingRow = DocumentRow(
			document: DocumentIdentifier(value: "d2"),
			condition: .inIngestion(stage: .classifying),
			title: nil,
			senderName: nil,
			documentDate: nil,
			arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
			amount: nil,
			passage: nil,
			contentKnown: true,
			suggestedFileName: "document.pdf"
		)
		let arriving = DocumentRowPresentation.from(arrivingRow, context: context)
		#expect(arriving.title == "Processing Document")
		#expect(arriving.thirdLineText == "Classifying document")
		#expect(arriving.thirdLineTone == .accent)
	}

	@Test func dayAndMonthLeavesTheYearToTheHeading() {
		let context = Self.fixedContext()
		#expect(DocumentFormatting
			.dayAndMonth(CalendarDate(year: 2026, month: 10, day: 31), context: context) == "31 Oct")
		#expect(DocumentFormatting.dayAndMonth(CalendarDate(year: 2026, month: 9, day: 2), context: context) == "2 Sep")
	}

	private static func listedRow(_ condition: DocumentCondition) -> DocumentRow {
		DocumentRow(
			document: DocumentIdentifier(value: "d1"),
			condition: condition,
			title: "Electricity Annual Statement 2026",
			senderName: "Stadtwerke Talbrück GmbH",
			documentDate: CalendarDate(year: 2026, month: 9, day: 22),
			arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
			amount: nil,
			passage: .summary(text: "Annual electricity statement for 2026."),
			contentKnown: true,
			suggestedFileName: "document.pdf"
		)
	}

	@Test func browsingDropsTheThirdLineOnlyOfAnArchivedDocument() {
		let context = Self.fixedContext()
		let browsed = DocumentRowPresentation.from(
			Self.listedRow(.archived),
			placement: .browsing(underMonth: false),
			context: context
		)
		#expect(!browsed.showsThirdLine)
		#expect(browsed.dateText == "22 Sep 2026")

		let arriving = DocumentRowPresentation.from(
			Self.listedRow(.inIngestion(stage: .classifying)),
			placement: .browsing(underMonth: false),
			context: context
		)
		#expect(arriving.thirdLineText == "Classifying document")

		let searched = DocumentRowPresentation.from(Self.listedRow(.archived), placement: .searching, context: context)
		#expect(searched.thirdLineText == "Annual electricity statement for 2026.")
	}

	@Test func aRowUnderAMonthShowsItsDayAndMonth() {
		let underMonth = DocumentRowPresentation.from(
			Self.listedRow(.archived),
			placement: .browsing(underMonth: true),
			context: Self.fixedContext()
		)
		#expect(underMonth.dateText == "22 Sep")
	}

	@Test func detailPresentationFormatsDecimalAmountsIbanPeriodsAndOfflinePlaceholder() {
		let context = Self.fixedContext()
		let senderScope = NamedScope(scope: .sender(sender: SenderIdentifier(value: "s1")), name: "Nordbank AG")
		let categoryScope = NamedScope(scope: .category(category: CategoryIdentifier(value: "c1")), name: "Invoice")
		let tagScope = NamedScope(scope: .tag(tag: TagIdentifier(value: "t1")), name: "strom")
		let detail = DocumentDetail(
			document: DocumentIdentifier(value: "d1"),
			condition: .archived,
			title: "Electricity Statement",
			documentDate: CalendarDate(year: 2026, month: 9, day: 22),
			sender: senderScope,
			category: categoryScope,
			person: .household,
			tags: [tagScope],
			summary: "Annual statement.",
			fields: [
				DetailField(key: "amount", value: .number(decimalText: "72.09")),
				DetailField(key: "currency", value: .text(text: "EUR")),
				DetailField(key: "due_date", value: .date(date: CalendarDate(year: 2026, month: 10, day: 6))),
				DetailField(key: "iban", value: .text(text: "DE89370400440532013000")),
				DetailField(key: "cancellation_period", value: .text(text: "P3M")),
			],
			originalKind: .portableDocument,
			byteSize: 125_400,
			pageCount: 3,
			arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
			archivePage: "https://archive.example.org/documents/d1",
			suggestedFileName: "2026-09-22 Nordbank AG Electricity Statement.pdf"
		)

		let presented = DocumentDetailPresentation.from(detail, context: context)
		#expect(presented.headerSubtitle == "Nordbank AG · 22 Sep 2026 · 3 pages")
		#expect(DocumentDetailPresentation.senderAndDate(of: detail, context: context) == "Nordbank AG · 22 Sep 2026")
		#expect(!presented.detailRows.contains { $0.label == "Currency" })

		let amountRow = presented.detailRows.first { $0.label == "Amount" }
		#expect(amountRow?.displayValue == "72.09 EUR")
		#expect(amountRow?.copyValue == "72.09")

		let ibanRow = presented.detailRows.first { $0.label == "IBAN" }
		#expect(ibanRow?.displayValue == "DE89 3704 0044 0532 0130 00")
		#expect(ibanRow?.copyValue == "DE89370400440532013000")

		let periodRow = presented.detailRows.first { $0.label == "Notice Period" }
		#expect(periodRow?.displayValue == "3 months")

		let dueRow = presented.detailRows.first { $0.label == "Due" }
		#expect(dueRow?.displayValue == "6 Oct 2026")
		#expect(dueRow?.copyValue == "2026-10-06")

		let macintosh = DeviceWording(phrase: "this Mac", storageLimitChoices: [])
		let offline = LibraryFailureWording.originalRefusalPlaceholder(.ArchiveUnreachable, device: macintosh)
		#expect(offline.title == "The Original Is Not on This Mac")
		#expect(offline.canRetry)
	}

	@Test func rowFromDetailMatchesTheRowOfTheListing() {
		let detail = DocumentDetail(
			document: DocumentIdentifier(value: "d1"),
			condition: .archived,
			title: "",
			documentDate: CalendarDate(year: 2026, month: 9, day: 22),
			sender: NamedScope(scope: .sender(sender: SenderIdentifier(value: "s1")), name: "Nordbank AG"),
			category: nil,
			person: nil,
			tags: [],
			summary: "Annual statement.",
			fields: [
				DetailField(key: "currency", value: .text(text: "EUR")),
				DetailField(key: "amount", value: .number(decimalText: "1234.5")),
			],
			originalKind: .portableDocument,
			byteSize: 125_400,
			pageCount: 3,
			arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
			archivePage: "https://archive.example.org/documents/d1",
			suggestedFileName: "2026-09-22 Nordbank AG.pdf"
		)
		let row = DocumentRowPresentation.from(detail, context: Self.fixedContext())
		#expect(row.title == "Untitled Document")
		#expect(row.sender == "Nordbank AG")
		#expect(row.dateText == "22 Sep 2026")
		#expect(row.amountText == "1,234.50 EUR")
		#expect(row.thirdLineText == "Annual statement.")
		#expect(row.thirdLineTone == .secondary)
	}
}
