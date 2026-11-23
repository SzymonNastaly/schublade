import ApplicationBindings
import Foundation
import LibraryPresentation
import XCTest
@testable import ApplicationInterface
@testable import SubmissionQueue

/// What the row of a sent letter says at each stage, from Save to its filed title.
final class ArrivalPresentationTests: XCTestCase {
	private static let savedAt = Date(timeIntervalSince1970: 1_795_425_120)
	private static let document = "0b7c4c1e-5d1f-4b8e-9a43-2f6d1c0e7a51"
	private static let context: WordingContext = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
		return WordingContext(now: savedAt, calendar: calendar, locale: Locale(identifier: "en_GB"))
	}()

	func testAScanBeingWrittenShowsItsPagesAndPreparing() {
		let preparing = PreparingSubmission(
			identifier: UUID(),
			origin: .scan,
			fileName: nil,
			pageCount: 3,
			startedAt: Self.savedAt
		)

		let arrival = ArrivalPresentation.arrival(preparing, context: Self.context)

		XCTAssertEqual(arrival.stage, .preparing)
		assertRow(arrival, title: "Scan", second: "3 pages · 9:12", third: "Preparing", trailing: .activity)
	}

	func testAQueuedScanThatSentNothingWaits() {
		let arrival = resolve(answer: nil, sentFraction: nil)

		XCTAssertEqual(arrival.stage, .waiting)
		assertRow(arrival, title: "Scan", second: "3 pages · 9:12", third: "Waiting to send", trailing: .absent)
	}

	func testAnUploadUnderWayShowsTheShareSent() {
		let arrival = resolve(answer: nil, sentFraction: 0.42)

		XCTAssertEqual(arrival.stage, .sending(fraction: 0.42))
		assertRow(arrival, title: "Scan", second: "3 pages · 9:12", third: "Sending", trailing: .progress(0.42))
		XCTAssertEqual(ArrivalPresentation.spokenStage(arrival, context: Self.context), "Sending, 42 per cent")
	}

	func testAnUnavailableArchiveIsTriedAgainOnSchedule() {
		let answeredAt = Self.savedAt.addingTimeInterval(60)

		let arrival = resolve(answer: .unavailable(attempts: 3, answeredAt: answeredAt), sentFraction: nil)

		XCTAssertEqual(arrival.stage, .retrying(nextAttempt: answeredAt.addingTimeInterval(240)))
		assertRow(
			arrival,
			title: "Scan",
			second: "3 pages · 9:12",
			third: "Waiting for the archive. Trying again at 9:17.",
			trailing: .absent
		)
	}

	func testAnArchivedScanTheCopyLacksIsSent() {
		let arrival = resolve(answer: archived(alreadyHeld: false), sentFraction: nil)

		XCTAssertEqual(arrival.stage, .sent)
		XCTAssertEqual(arrival.document, DocumentIdentifier(value: Self.document))
		assertRow(arrival, title: "Scan", second: "3 pages · 9:12", third: "Sent", trailing: .done(filed: false))
	}

	func testADocumentInIngestionShowsTheArchivesStage() {
		let arrival = resolve(
			answer: archived(alreadyHeld: false),
			sentFraction: nil,
			document: detail(condition: .inIngestion(stage: .recognizingText), title: nil)
		)

		XCTAssertEqual(arrival.stage, .reading(.recognizingText))
		assertRow(
			arrival,
			title: "Scan",
			second: "3 pages · 9:12",
			third: "Recognizing text",
			trailing: .done(filed: false)
		)
	}

	func testAFiledDocumentShowsItsTitleSenderDateAndAmount() {
		let arrival = resolve(
			answer: archived(alreadyHeld: false),
			sentFraction: nil,
			document: detail(condition: .archived, title: "Frischemarkt Talbrück Receipt October 2026")
		)

		let row = ArrivalPresentation.row(arrival, context: Self.context)
		XCTAssertEqual(row.title, "Frischemarkt Talbrück Receipt October 2026")
		XCTAssertEqual(row.sender, "Frischemarkt Talbrück GmbH")
		XCTAssertEqual(row.dateText, "31 Oct 2026")
		XCTAssertEqual(row.amountText, "29.63 EUR")
		XCTAssertEqual(row.thirdLineText, "")
		XCTAssertEqual(ArrivalPresentation.trailing(arrival.stage), .done(filed: true))
	}

	func testBytesTheArchiveHeldShowItsDocument() {
		let arrival = resolve(
			answer: archived(alreadyHeld: true),
			sentFraction: nil,
			document: detail(condition: .archived, title: "Frischemarkt Talbrück Receipt October 2026")
		)

		let row = ArrivalPresentation.row(arrival, context: Self.context)
		XCTAssertEqual(row.title, "Frischemarkt Talbrück Receipt October 2026")
		XCTAssertEqual(row.thirdLineText, "Already in the archive")
		XCTAssertEqual(ArrivalPresentation.trailing(arrival.stage), .absent)
	}

	func testARejectedFileSaysTheArchivesReason() {
		let arrival = resolve(
			answer: .rejected(reason: "Only PDF, JPEG, PNG, and WebP files can be archived", answeredAt: Self.savedAt),
			sentFraction: nil
		)

		XCTAssertEqual(arrival.stage, .notAccepted(reason: "Only PDF, JPEG, PNG, and WebP files can be archived"))
		assertRow(
			arrival,
			title: "Scan",
			second: "3 pages · 9:12",
			third: "Not accepted. Only PDF, JPEG, PNG, and WebP files can be archived.",
			trailing: .attention
		)
	}

	func testARefusedTokenSaysSo() {
		let arrival = resolve(answer: .refusedToken(answeredAt: Self.savedAt), sentFraction: nil)

		XCTAssertEqual(arrival.stage, .tokenRefused)
		assertRow(
			arrival,
			title: "Scan",
			second: "3 pages · 9:12",
			third: "The archive refused the token.",
			trailing: .attention
		)
	}

	func testAFailedDocumentSaysWhy() {
		let arrival = resolve(
			answer: archived(alreadyHeld: false),
			sentFraction: nil,
			document: detail(condition: .failed(reason: .unreadablePage), title: nil)
		)

		XCTAssertEqual(arrival.stage, .failed(.unreadablePage, title: nil))
		assertRow(
			arrival,
			title: "Scan",
			second: "3 pages · 9:12",
			third: "A page could not be read in any orientation.",
			trailing: .attention
		)
	}

	func testAFileIsNamedWithoutItsExtensionAndMeasuredInBytes() {
		let manifest = SubmissionManifest(
			identifier: UUID(),
			origin: .share,
			fileName: "Invoice 10.2026.pdf",
			kind: .pdf,
			byteCount: 1_234_567,
			pageCount: nil,
			createdAt: Self.savedAt,
			uploadClaimedAt: Self.savedAt
		)

		let arrival = ArrivalPresentation.arrival(
			SubmissionEntry(manifest: manifest, answer: nil),
			sentFraction: nil,
			document: nil,
			context: Self.context
		)

		XCTAssertEqual(arrival.displayName, "Invoice 10.2026")
		XCTAssertEqual(arrival.facts, "1.2 MB · 9:12")
	}

	private func resolve(
		answer: SubmissionAnswerRecord?,
		sentFraction: Double?,
		document: DocumentDetail? = nil
	) -> Arrival {
		let manifest = SubmissionManifest(
			identifier: UUID(),
			origin: .scan,
			fileName: "Scan 2026-11-23 09.12.pdf",
			kind: .pdf,
			byteCount: 2_400_000,
			pageCount: 3,
			createdAt: Self.savedAt,
			uploadClaimedAt: nil
		)
		return ArrivalPresentation.arrival(
			SubmissionEntry(manifest: manifest, answer: answer),
			sentFraction: sentFraction,
			document: document,
			context: Self.context
		)
	}

	private func archived(alreadyHeld: Bool) -> SubmissionAnswerRecord {
		.archived(document: Self.document, alreadyHeld: alreadyHeld, answeredAt: Self.savedAt)
	}

	private func detail(condition: DocumentCondition, title: String?) -> DocumentDetail {
		DocumentDetail(
			document: DocumentIdentifier(value: Self.document),
			condition: condition,
			title: title,
			documentDate: CalendarDate(year: 2026, month: 10, day: 31),
			sender: NamedScope(
				scope: .sender(sender: SenderIdentifier(value: "20000000-0000-4000-8000-000000000001")),
				name: "Frischemarkt Talbrück GmbH"
			),
			category: nil,
			person: nil,
			tags: [],
			summary: nil,
			fields: [
				DetailField(key: "amount", value: .number(decimalText: "29.63")),
				DetailField(key: "currency", value: .text(text: "EUR")),
			],
			originalKind: .portableDocument,
			byteSize: 2_400_000,
			pageCount: 3,
			arrivedAt: Self.savedAt,
			archivePage: "http://127.0.0.1/documents/\(Self.document)",
			suggestedFileName: "Receipt.pdf"
		)
	}

	private func assertRow(
		_ arrival: Arrival,
		title: String,
		second: String,
		third: String,
		trailing: RowTrailing,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let row = ArrivalPresentation.row(arrival, context: Self.context)
		XCTAssertEqual(row.title, title, file: file, line: line)
		XCTAssertEqual(row.sender, second, file: file, line: line)
		XCTAssertEqual(row.thirdLineText, third, file: file, line: line)
		XCTAssertEqual(ArrivalPresentation.trailing(arrival.stage), trailing, file: file, line: line)
	}
}
