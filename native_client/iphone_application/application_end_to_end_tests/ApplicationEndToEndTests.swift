import ApplicationBindings
import Foundation
import LibraryPresentation
import SubmissionQueue
import UIKit
import XCTest
@testable import ApplicationInterface

/// The Rust core on the iPhone: started without a collector, connected to the scripted archive
/// that the check script runs on the Mac, and filled with the seeded documents.
final class ApplicationEndToEndTests: XCTestCase {
	/// `check_application.sh` starts `scripted-archive-server` with this token and five documents and
	/// passes its address through `TEST_RUNNER_SCHUBLADE_SCRIPTED_ARCHIVE`.
	private static let token = "scripted-end-to-end-token"
	private static let seededDocuments: UInt64 = 5

	@MainActor
	func testTheCoreConnectsAndCopiesTheArchive() async throws {
		let gateway = ApplicationGateway()
		try await gateway.start(configuration: ApplicationEnvironment.isolated().applicationConfiguration)

		let grant = try await gateway.connectArchive(address: Self.archiveAddress(), token: Self.token)
		XCTAssertTrue(grant.reads)
		XCTAssertFalse(grant.collects)

		let status = try await Self.awaitDocuments(Self.seededDocuments, in: gateway)
		let listing = try await gateway.listDocuments(
			request: .browse(scope: .allDocuments, order: .documentDate)
		)
		XCTAssertEqual(UInt64(listing.documentCount()), status.counts.documents)
		await gateway.shutdown()
	}

	/// The token written through the iPhone's Keychain store is read again by the next start, which
	/// therefore synchronizes a document that arrived while the core was stopped.
	@MainActor
	func testTheKeychainKeepsTheTokenAcrossStarts() async throws {
		var configuration = ApplicationEnvironment.isolated().applicationConfiguration
		configuration.credentialStorage = .sharedKeychain(
			serviceName: "org.schublade.iphone.end-to-end-tests.\(UUID().uuidString)",
			accessGroup: nil
		)

		let first = ApplicationGateway()
		try await first.start(configuration: configuration)
		_ = try await first.connectArchive(address: Self.archiveAddress(), token: Self.token)
		let filled = try await Self.awaitDocuments(Self.seededDocuments, in: first)
		await first.shutdown()

		try await Self.addDocument()
		let second = ApplicationGateway()
		try await second.start(configuration: configuration)
		_ = try await Self.awaitDocuments(filled.counts.documents + 1, in: second)
		await second.shutdown()
	}

	/// A scan's body prepared in Rust with its text and the Keychain's token, put by `URLSession`, its
	/// answer read in Rust, its text in the archive, and its document in the library.
	@MainActor
	func testASentScanArrivesInTheLibrary() async throws {
		var configuration = ApplicationEnvironment.isolated().applicationConfiguration
		let credentials = CredentialStorage.sharedKeychain(
			serviceName: "org.schublade.iphone.end-to-end-tests.\(UUID().uuidString)",
			accessGroup: nil
		)
		configuration.credentialStorage = credentials
		let gateway = ApplicationGateway()
		try await gateway.start(configuration: configuration)
		let grant = try await gateway.connectArchive(address: Self.archiveAddress(), token: Self.token)
		let filled = try await Self.awaitDocuments(Self.seededDocuments, in: gateway)

		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let scan = directory.appending(path: "document.pdf")
		let letter = "A letter scanned on the iPhone \(UUID().uuidString)"
		try Data("%PDF-1.4\n\(letter)\n%%EOF\n".utf8).write(to: scan)
		let body = directory.appending(path: "request_body")
		let prepared = try prepareDocumentSubmission(
			archiveOrigin: grant.origin,
			credentialStorage: credentials,
			documentPath: scan.path(percentEncoded: false),
			pageTexts: [letter],
			thumbnailPath: nil,
			destinationPath: body.path(percentEncoded: false)
		)
		var request = try URLRequest(url: XCTUnwrap(URL(string: prepared.url)))
		request.httpMethod = "PUT"
		prepared.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
		let (answerBody, response) = try await URLSession.shared.upload(for: request, fromFile: body)
		let answered = try XCTUnwrap(response as? HTTPURLResponse)
		let answer = readDocumentSubmissionAnswer(
			status: UInt16(answered.statusCode),
			contentType: answered.value(forHTTPHeaderField: "Content-Type"),
			body: answerBody
		)
		guard case let .archived(document, alreadyHeld: false) = answer else {
			return XCTFail("The archive answered \(answer)")
		}
		let textAddress = try XCTUnwrap(URL(string: "\(grant.origin)/api/v1/documents/\(document.value)/text"))
		var textRequest = URLRequest(url: textAddress)
		textRequest.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
		let (text, _) = try await URLSession.shared.data(for: textRequest)
		XCTAssertEqual(String(bytes: text, encoding: .utf8), "## Page 1\n\n\(letter)\n", "the archive holds the text")
		gateway.synchronize()
		_ = try await Self.awaitDocuments(filled.counts.documents + 1, in: gateway)
		await gateway.shutdown()
	}

	/// What the background refresh does in the time the system grants: a document added to the archive
	/// while no screen attends the copy, which then reads the archive every 15 minutes, is in the copy
	/// once the refresh answers.
	@MainActor
	func testARefreshReadsADocumentAddedMeanwhile() async throws {
		let controller = ApplicationController(environment: .isolated())
		controller.launch()
		try await waitUntil("the core starts") { controller.situation != .starting }
		let refusal = try await controller.connect(address: Self.archiveAddress(), token: Self.token)
		XCTAssertNil(refusal)
		let filledAnswer = try await Self.refresh(controller)
		XCTAssertEqual(filledAnswer, .synchronized)
		let filled = try await controller.gateway.libraryStatusAfter(nil)

		try await Self.addDocument()
		let answer = try await Self.refresh(controller)

		XCTAssertEqual(answer, .synchronized)
		let status = try await controller.gateway.libraryStatusAfter(nil)
		XCTAssertEqual(status.counts.documents, filled.counts.documents + 1)
		await controller.gateway.shutdown()
	}

	/// A token the archive no longer accepts leaves the copy, a scan, and a share sent meanwhile
	/// waiting for the person, and the token that replaces it, connected as the replace form does, lets
	/// the copy read the archive again and sends both at once, the share although the share extension
	/// claimed its upload a moment ago.
	@MainActor
	func testAReplacedTokenLetsTheCopyReadAgainAndSendsWhatItHeld() async throws {
		let controller = ApplicationController(environment: .isolated())
		controller.launch()
		try await waitUntil("the core starts") { controller.situation != .starting }
		let refusal = try await controller.connect(address: Self.archiveAddress(), token: Self.token)
		XCTAssertNil(refusal)
		let filledAnswer = try await Self.refresh(controller)
		XCTAssertEqual(filledAnswer, .synchronized)

		let replacement = "replaced-end-to-end-token"
		try await Self.acceptOnly(replacement)
		addTeardownBlock {
			try await Self.acceptOnly(Self.token)
		}
		let refusedAnswer = try await Self.refresh(controller)
		XCTAssertEqual(refusedAnswer, .withheld)
		let refused = try await controller.gateway.libraryStatusAfter(nil)
		XCTAssertEqual(ConnectionAttention.resolve(refused.archive), .tokenRefused)
		try controller.submissions.submit(
			document: Self.letter("A letter scanned while the token was refused"),
			fileName: "Scan.pdf",
			kind: .pdf,
			origin: .scan,
			pageCount: 1
		)
		try await waitUntil("the archive refuses the scan's token") {
			controller.submissions.entries.first?.answer?.refusedTheToken == true
		}
		// The share extension records the archive's refusal of a share as the application does.
		let queue = controller.environment.sharedContainer.submissionQueue
		let share = try queue.enqueue(
			document: Self.letter("A letter shared while the token was refused"),
			fileName: "Letter.pdf",
			kind: .pdf,
			origin: .share,
			claimingUpload: true
		)
		try queue.record(.refusedToken(answeredAt: .now), for: share.id)

		let replacementRefusal = try await controller.connect(address: Self.archiveAddress(), token: replacement)
		XCTAssertNil(replacementRefusal)
		let replacedAnswer = try await Self.refresh(controller)
		XCTAssertEqual(replacedAnswer, .synchronized)
		let status = try await controller.gateway.libraryStatusAfter(nil)
		XCTAssertNil(ConnectionAttention.resolve(status.archive))
		try await waitUntil("the held scan and share are archived") {
			controller.submissions.entries.count == 2
				&& controller.submissions.entries.allSatisfy { $0.answer?.archivedTheBytes == true }
		}
		await controller.gateway.shutdown()
	}

	/// A seeded document opened from the list as a person taps its row: the page reads the detail into
	/// its details sheet, the original as a PDF of one page, and the extracted text on the page that
	/// the sheet's Extracted Text row pushes.
	@MainActor
	func testADocumentOpensFromTheList() async throws {
		let controller = ApplicationController(environment: .isolated())
		controller.launch()
		try await waitUntil("the core starts") { controller.situation != .starting }
		let refusal = try await controller.connect(address: Self.archiveAddress(), token: Self.token)
		XCTAssertNil(refusal)
		let library = LibraryViewController(controller: controller)
		let navigation = UINavigationController(rootViewController: library)
		let window = try TestWindow.showing(navigation)
		defer { window.close() }
		try await waitUntil("the seeded documents are listed") { Self.listedRows(library).count == 5 }
		guard case let .documents(sections) = library.state else {
			return XCTFail("The list shows \(library.state)")
		}
		XCTAssertEqual(
			sections.map { $0.heading.map { DocumentFormatting.headingText($0, context: .current()) } },
			["September 2026"]
		)
		let row = try XCTUnwrap(sections.first?.rows.first)
		XCTAssertEqual(row.title, "Haftpflichtversicherung Rechnung 5")

		let page = try await Self.tap(row, in: library)
		XCTAssertEqual(page.title, "Haftpflichtversicherung Rechnung 5")
		try await waitUntil("the original shows as a PDF") {
			if case let .portableDocument(document)? = page.original?.state {
				document.pageCount == 1
			} else {
				false
			}
		}

		try await waitUntil("the details sheet shows") {
			page.presentedViewController?.isBeingPresented == false
		}
		let detailRows = page.details.sections.flatMap(\.rows)
		guard case let .head(title, _)? = detailRows.first else {
			return XCTFail("The details sheet begins with \(String(describing: detailRows.first))")
		}
		XCTAssertEqual(title, "Haftpflichtversicherung Rechnung 5")

		try Self.select(.extractedText, in: page.details)
		try await waitUntil("the text page shows") { navigation.topViewController is DocumentTextViewController }
		let textPage = try XCTUnwrap(navigation.topViewController as? DocumentTextViewController)
		XCTAssertNil(page.presentedViewController)
		try await waitUntil("the extracted text shows") {
			if case let .text(text) = textPage.state {
				text.contains("Rechnung Nummer 5 für Haftpflichtversicherung.")
			} else {
				false
			}
		}
		await controller.gateway.shutdown()
	}
}

/// What the tests do as a person or as the archive's owner would, and what they wait for.
private extension ApplicationEndToEndTests {
	/// Taps the row as a person does and waits until the page has read the document's detail.
	@MainActor
	static func tap(
		_ row: DocumentRow,
		in library: LibraryViewController
	) async throws -> DocumentPageViewController {
		let indexPath = try XCTUnwrap(library.list.indexPath(of: .document(row.document)))
		let rows = library.list.collectionView
		rows.delegate?.collectionView?(rows, didSelectItemAt: indexPath)
		let page = try XCTUnwrap(library.navigationController?.topViewController as? DocumentPageViewController)
		page.loadViewIfNeeded()
		try await waitUntil("the detail is read") {
			if case .loaded = page.detailState {
				true
			} else {
				false
			}
		}
		return page
	}

	/// Taps a row of the details sheet as a person does.
	@MainActor
	static func select(_ row: DocumentDetailRow, in details: DocumentDetailsViewController) throws {
		let sectionIndex = try XCTUnwrap(details.sections.firstIndex { $0.rows.contains(row) })
		let indexPath = try IndexPath(
			item: XCTUnwrap(details.sections[sectionIndex].rows.firstIndex(of: row)),
			section: sectionIndex
		)
		let list = try XCTUnwrap(details.view.subviews.lazy.compactMap { $0 as? UICollectionView }.first)
		XCTAssertTrue(details.collectionView(list, shouldSelectItemAt: indexPath))
		details.collectionView(list, didSelectItemAt: indexPath)
	}

	@MainActor
	static func listedRows(_ library: LibraryViewController) -> [DocumentRow] {
		guard case let .documents(sections) = library.state else {
			return []
		}
		return sections.flatMap(\.rows)
	}

	static func archiveAddress() throws -> String {
		try XCTUnwrap(
			ProcessInfo.processInfo.environment["SCHUBLADE_SCRIPTED_ARCHIVE"],
			"The check script passes the scripted archive's address"
		)
	}

	/// Follows the library until its copy holds at least `count` documents. After 30 seconds it shuts
	/// the core down, which ends the waiting read, because a read in Rust ignores cancellation.
	@MainActor
	static func awaitDocuments(_ count: UInt64, in gateway: ApplicationGateway) async throws -> LibraryStatus {
		var latest: LibraryStatus?
		let timeout = Task { @MainActor in
			try await Task.sleep(for: .seconds(30))
			await gateway.shutdown()
		}
		defer { timeout.cancel() }
		do {
			var status = try await gateway.libraryStatusAfter(nil)
			latest = status
			while status.counts.documents < count {
				status = try await gateway.libraryStatusAfter(status.revision)
				latest = status
			}
			return status
		} catch {
			throw ConditionNotReached(
				expectation: "\(count) documents in the copy within 30 seconds",
				detail: latest.map { "\($0)" } ?? "no status"
			)
		}
	}

	/// Asks the copy to read the archive, as the background refresh does. After 30 seconds it shuts the
	/// core down, which ends the refresh's waiting read, and fails, so an archive out of reach fails
	/// the test rather than holding it.
	@MainActor
	static func refresh(_ controller: ApplicationController) async throws -> SynchronizationAnswer {
		let timeout = Task { @MainActor () -> Bool in
			do {
				try await Task.sleep(for: .seconds(30))
			} catch {
				return false
			}
			await controller.gateway.shutdown()
			return true
		}
		let answer = await controller.refreshLibrary()
		timeout.cancel()
		if await timeout.value {
			throw ConditionNotReached(expectation: "the refresh answers within 30 seconds", detail: "\(answer)")
		}
		return answer
	}

	static func letter(_ text: String) throws -> URL {
		let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
		try Data("%PDF-1.4\n\(text) \(UUID().uuidString)\n%%EOF\n".utf8).write(to: file)
		return file
	}

	/// Makes the scripted archive accept only this token, as when its owner revokes another.
	static func acceptOnly(_ token: String) async throws {
		let address = try XCTUnwrap(URL(string: archiveAddress()))
		var request = URLRequest(url: address.appending(path: "scripted/token"))
		request.httpMethod = "POST"
		request.httpBody = Data(token.utf8)
		let (_, response) = try await URLSession.shared.data(for: request)
		let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
		guard status == 204 else {
			throw ConditionNotReached(expectation: "POST /scripted/token answers 204", detail: "status \(status)")
		}
	}

	/// Adds one archived document to the scripted archive.
	static func addDocument() async throws {
		let address = try XCTUnwrap(URL(string: archiveAddress()))
		var request = URLRequest(url: address.appending(path: "scripted/documents"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = Data("""
		{"identifier": "\(UUID().uuidString.lowercased())", "title": "Water bill", "document_date": "2026-11-01",
		 "sender_name": "Stadtwerke", "category_name": "Invoice", "summary": "The water bill for October."}
		""".utf8)
		let (_, response) = try await URLSession.shared.data(for: request)
		let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
		guard status == 200 else {
			throw ConditionNotReached(expectation: "POST /scripted/documents answers 200", detail: "status \(status)")
		}
	}
}

private extension SubmissionAnswerRecord {
	var refusedTheToken: Bool {
		if case .refusedToken = self {
			true
		} else {
			false
		}
	}

	var archivedTheBytes: Bool {
		if case .archived = self {
			true
		} else {
			false
		}
	}
}
