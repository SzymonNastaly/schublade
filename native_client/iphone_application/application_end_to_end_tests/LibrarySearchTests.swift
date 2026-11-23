import ApplicationBindings
import XCTest
@testable import ApplicationInterface

/// What the search field offers for a typed text, and what an excerpt marks.
final class LibrarySearchTests: XCTestCase {
	@MainActor
	private static func count(_ scope: LibraryScope, _ name: String) -> ScopeCount {
		ScopeCount(scope: NamedScope(scope: scope, name: name), documents: 1)
	}

	/// "rec" offers the Receipt category, and "pre" the tag Prämie by a word inside its name, whatever
	/// the case and the diacritics. The chosen scope is not offered again, and at most three are.
	@MainActor
	func testATypedTextOffersTheScopesWhoseNamesItBegins() {
		let receipt = LibraryScope.category(category: CategoryIdentifier(value: "c1"))
		let facets = LibraryFacets(
			contentRevision: 1,
			documents: 9,
			documentsInIngestion: 0,
			documentsFailed: 0,
			householdDocuments: 9,
			members: [
				Self.count(.member(member: MemberIdentifier(value: "m1")), "Lena Becker"),
				Self.count(.member(member: MemberIdentifier(value: "m2")), "Recep Yilmaz"),
			],
			categories: [
				Self.count(receipt, "Receipt"),
				Self.count(.category(category: CategoryIdentifier(value: "c2")), "Invoice"),
			],
			tags: [
				Self.count(.tag(tag: TagIdentifier(value: "t1")), "Versicherung Prämie"),
				Self.count(.tag(tag: TagIdentifier(value: "t2")), "Rechnung"),
			]
		)

		let offered = { (text: String, chosen: LibraryScope) in
			LibrarySearch.suggestions(for: text, facets: facets, chosen: chosen).map { "\($0.scope.name) \($0.kind)" }
		}

		XCTAssertEqual(offered("Rec", .allDocuments), ["Receipt Category", "Rechnung Tag", "Recep Yilmaz Person"])
		XCTAssertEqual(offered("rec", receipt), ["Rechnung Tag", "Recep Yilmaz Person"])
		XCTAssertEqual(offered("pra", .allDocuments), ["Versicherung Prämie Tag"])
		XCTAssertEqual(offered("becker", .allDocuments), ["Lena Becker Person"])
		XCTAssertEqual(offered(" ", .allDocuments), [])
		XCTAssertEqual(offered("statement", .allDocuments), [])
	}

	/// Every occurrence of each word, whatever the case and the diacritics, and overlapping matches as one.
	@MainActor
	func testAnExcerptMarksEachOccurrenceOfTheSearchedWords() {
		let excerpt = "Prämie der Haftpflicht: die PRAMIE für Haftpflichtversicherung"

		let marked = LibrarySearch.matchedRanges(in: excerpt, searchText: "pramie  haftpflicht pflicht")
			.map { String(excerpt[$0]) }

		XCTAssertEqual(marked, ["Prämie", "Haftpflicht", "PRAMIE", "Haftpflicht"])
	}
}
