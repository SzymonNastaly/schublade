import ApplicationBindings
import Foundation
import PDFKit
import SubmissionQueue
import UIKit
import XCTest
@testable import ApplicationInterface

/// Sending as a person does it: a scan written as a PDF, and a submission that goes through the
/// queue, the transfer, and the archive into the library.
final class SubmissionTests: XCTestCase {
	/// Three photographed A4 pages at 12 megapixels become a PDF of three A4 pages within the limit.
	func testAScanBecomesOnePortableDocumentOfItsPages() throws {
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		let pages = (1 ... 3).map { number in
			UIGraphicsImageRenderer(size: CGSize(width: 2976, height: 4209), format: format).image { context in
				UIColor.white.setFill()
				context.fill(CGRect(x: 0, y: 0, width: 2976, height: 4209))
				NSAttributedString(
					string: "Page \(number) of a letter from the Stadtwerke",
					attributes: [.font: UIFont.systemFont(ofSize: 120)]
				).draw(at: CGPoint(x: 200, y: 300))
			}
		}
		let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")

		let bytes = try ScanDocumentWriter.write(pages: pages, to: file)

		let document = try XCTUnwrap(PDFDocument(url: file))
		XCTAssertEqual(document.pageCount, 3)
		let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
		XCTAssertEqual(bounds.width, 595, accuracy: 1)
		XCTAssertEqual(bounds.height, 842, accuracy: 1)
		XCTAssertLessThan(bytes, ScanDocumentWriter.byteLimit)
	}

	/// A submitted PDF is sent, answered as archived, gives up its bytes, and arrives in the library.
	@MainActor
	func testASubmittedDocumentIsArchivedAndArrivesInTheLibrary() async throws {
		let environment = ApplicationEnvironment.isolated()
		let controller = ApplicationController(environment: environment)
		controller.launch()
		let address = try XCTUnwrap(ProcessInfo.processInfo.environment["SCHUBLADE_SCRIPTED_ARCHIVE"])
		try await waitUntil("the core starts") { controller.archiveOrigin == nil && controller.situation != .starting }
		let refusal = await controller.connect(address: address, token: "scripted-end-to-end-token")
		XCTAssertNil(refusal)
		try await waitUntil("five documents") { Self.documents(controller) >= 5 }
		let before = Self.documents(controller)

		let scan = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
		try Data("%PDF-1.4\nA letter sent through the queue \(UUID().uuidString)\n%%EOF\n".utf8).write(to: scan)
		try controller.submissions.submit(document: scan, fileName: "Scan.pdf", kind: .pdf, origin: .scan, pageCount: 1)

		try await waitUntil("the submission is archived") {
			if case .archived = controller.submissions.entries.first?.answer {
				true
			} else {
				false
			}
		}
		let entry = try XCTUnwrap(controller.submissions.entries.first)
		XCTAssertNil(controller.submissions.documentFile(of: entry))
		try await waitUntil("the document arrives in the library") { Self.documents(controller) == before + 1 }
		await controller.gateway.shutdown()
	}

	@MainActor
	func testConnectingRecordsTheArchiveForTheShareExtension() async throws {
		let environment = ApplicationEnvironment.isolated()
		let controller = ApplicationController(environment: environment)
		controller.launch()
		let address = try XCTUnwrap(ProcessInfo.processInfo.environment["SCHUBLADE_SCRIPTED_ARCHIVE"])
		try await waitUntil("the core starts") { controller.situation != .starting }
		XCTAssertNil(environment.sharedContainer.connectedArchive())

		let refusal = await controller.connect(address: address, token: "scripted-end-to-end-token")
		XCTAssertNil(refusal)

		try await waitUntil("the archive is recorded") { environment.sharedContainer.connectedArchive() != nil }
		XCTAssertEqual(
			environment.sharedContainer.connectedArchive(),
			ConnectedArchive(origin: address, restricted: false)
		)
		await controller.gateway.shutdown()
	}

	/// The share extension claims the upload of each submission it creates. The application sends a
	/// claimed submission without an answer only once the claim is 15 minutes old, as when the
	/// extension was ended before its upload started, and an unclaimed one at once.
	@MainActor
	func testAClaimedSubmissionIsLeftToTheShareExtensionForFifteenMinutes() async throws {
		let environment = ApplicationEnvironment.isolated()
		let controller = ApplicationController(environment: environment)
		controller.launch()
		let address = try XCTUnwrap(ProcessInfo.processInfo.environment["SCHUBLADE_SCRIPTED_ARCHIVE"])
		try await waitUntil("the core starts") { controller.situation != .starting }
		_ = await controller.connect(address: address, token: "scripted-end-to-end-token")
		try await waitUntil("five documents") { Self.documents(controller) >= 5 }
		let before = Self.documents(controller)
		let queue = environment.sharedContainer.submissionQueue
		let claimedAt = Date.now
		let claimed = try queue.enqueue(
			document: Self.letter("A letter shared from Mail"),
			fileName: "Letter.pdf",
			kind: .pdf,
			origin: .share,
			claimingUpload: true,
			now: claimedAt
		)
		let unclaimed = try queue.enqueue(
			document: Self.letter("A letter imported from Files"),
			fileName: "Receipt.pdf",
			kind: .pdf,
			origin: .importedFile
		)

		controller.submissions.resume(now: claimedAt.addingTimeInterval(14 * 60))
		try await waitUntil("the unclaimed submission is archived") { Self.isArchived(unclaimed, controller) }
		try await Task.sleep(for: .seconds(1))
		XCTAssertEqual(controller.submissions.entries.first { $0.id == claimed.id }?.answer, nil)

		controller.submissions.resume(now: claimedAt.addingTimeInterval(16 * 60))
		try await waitUntil("the claimed submission is archived") { Self.isArchived(claimed, controller) }
		try await waitUntil("both documents arrive in the library") { Self.documents(controller) == before + 2 }
		await controller.gateway.shutdown()
	}

	private static func letter(_ text: String) throws -> URL {
		let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
		try Data("%PDF-1.4\n\(text) \(UUID().uuidString)\n%%EOF\n".utf8).write(to: file)
		return file
	}

	@MainActor
	private static func isArchived(_ entry: SubmissionEntry, _ controller: ApplicationController) -> Bool {
		if case .archived = controller.submissions.entries.first(where: { $0.id == entry.id })?.answer {
			true
		} else {
			false
		}
	}

	@MainActor
	private static func documents(_ controller: ApplicationController) -> UInt64 {
		guard case let .running(status) = controller.situation else {
			return 0
		}
		return status.counts.documents
	}

	@MainActor
	private func waitUntil(_ expectation: String, condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now + .seconds(30)
		while !condition() {
			guard ContinuousClock.now < deadline else {
				throw ConditionNotReached(expectation: expectation, detail: "not within 30 seconds")
			}
			try await Task.sleep(for: .milliseconds(50))
		}
	}
}
