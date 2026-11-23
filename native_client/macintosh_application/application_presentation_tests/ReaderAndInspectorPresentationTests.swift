import ApplicationBindings
import ApplicationPresentation
import Foundation
import LibraryPresentation
import Testing

/// The inspector's sections.
struct ReaderAndInspectorPresentationTests {
	private static func invoice(tags: [NamedScope]) -> DocumentDetail {
		DocumentDetail(
			document: DocumentIdentifier(value: "d1"),
			condition: .archived,
			title: "Electricity Statement",
			documentDate: CalendarDate(year: 2026, month: 9, day: 22),
			sender: NamedScope(scope: .sender(sender: SenderIdentifier(value: "s1")), name: "Nordbank AG"),
			category: NamedScope(scope: .category(category: CategoryIdentifier(value: "c1")), name: "Invoice"),
			person: .household,
			tags: tags,
			summary: "Annual statement.",
			fields: [
				DetailField(key: "amount", value: .number(decimalText: "72.09")),
				DetailField(key: "currency", value: .text(text: "EUR")),
				DetailField(key: "iban", value: .text(text: "DE89370400440532013000")),
			],
			originalKind: .portableDocument,
			byteSize: 125_400,
			pageCount: 2,
			arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
			archivePage: "https://archive.example.org/documents/d1",
			suggestedFileName: "2026-09-22 Nordbank AG Electricity Statement.pdf"
		)
	}

	@Test func theInspectorPutsTheFactsBeforeThePlacesADocumentIsFiledUnder() {
		let tag = NamedScope(scope: .tag(tag: TagIdentifier(value: "t1")), name: "strom")
		let inspector = InspectorPresentation.from(
			Self.invoice(tags: [tag]),
			context: WindowContentAndSidebarTests.fixedContext().library
		)
		#expect(inspector.title == "Electricity Statement")
		#expect(inspector.summary == "Annual statement.")
		#expect(inspector.fileLine == "2 pages · PDF")
		#expect(inspector.facts.map(\.label) == ["Date", "Amount", "IBAN"])
		#expect(inspector.facts.map(\.copyValue) == ["2026-09-22", "72.09", "DE89370400440532013000"])
		#expect(inspector.filedUnder.map(\.label) == ["Sender", "Category", "Person"])
		#expect(inspector.filedUnder.map(\.displayValue) == ["Nordbank AG", "Invoice", "Household"])
		#expect(inspector.tags == [tag])
		#expect(inspector.fileFacts.map(\.label) == ["Size", "Added"])
	}
}
