import ApplicationBindings
import Foundation
import LibraryPresentation
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

	/// A scan sent as the iPhone sends it: the body prepared in Rust with the token from the Keychain,
	/// uploaded from its file by `URLSession`, its answer read in Rust, and the new document
	/// copied into the library, which an archived answer asks to synchronize at once.
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
		try Data("%PDF-1.4\nA letter scanned on the iPhone \(UUID().uuidString)\n%%EOF\n".utf8).write(to: scan)
		let body = directory.appending(path: "request_body")
		let prepared = try prepareDocumentSubmission(
			archiveOrigin: grant.origin,
			credentialStorage: credentials,
			documentPath: scan.path(percentEncoded: false),
			fileName: "Scan 2026-11-22.pdf",
			mediaType: .pdf,
			destinationPath: body.path(percentEncoded: false)
		)
		var request = try URLRequest(url: XCTUnwrap(URL(string: prepared.url)))
		request.httpMethod = "POST"
		request.setValue(prepared.contentType, forHTTPHeaderField: "Content-Type")
		request.setValue(prepared.authorization, forHTTPHeaderField: "Authorization")
		let (answerBody, response) = try await URLSession.shared.upload(for: request, fromFile: body)
		let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
		let answer = readDocumentSubmissionAnswer(status: UInt16(status), body: answerBody)
		guard case .archived(_, alreadyHeld: false) = answer else {
			return XCTFail("The archive answered \(answer)")
		}

		gateway.synchronize()
		_ = try await Self.awaitDocuments(filled.counts.documents + 1, in: gateway)
		await gateway.shutdown()
	}

	/// A seeded document opened from the list as a person taps its row: the page reads the detail, the
	/// original as a PDF of one page, and the extracted text.
	@MainActor
	func testADocumentOpensFromTheList() async throws {
		let controller = ApplicationController(environment: .isolated())
		controller.launch()
		try await waitUntil("the core starts") { controller.situation != .starting }
		let refusal = try await controller.connect(address: Self.archiveAddress(), token: Self.token)
		XCTAssertNil(refusal)
		let library = LibraryViewController(controller: controller)
		let navigation = UINavigationController(rootViewController: library)
		library.loadViewIfNeeded()
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

		let indexPath = try XCTUnwrap(library.list.indexPath(of: .document(row.document)))
		library.collectionView(library.list.collectionView, didSelectItemAt: indexPath)
		let page = try XCTUnwrap(navigation.topViewController as? DocumentPageViewController)
		page.loadViewIfNeeded()
		try await waitUntil("the detail is read") {
			if case .loaded = page.detailState {
				true
			} else {
				false
			}
		}
		XCTAssertEqual(page.title, "Haftpflichtversicherung Rechnung 5")
		try await waitUntil("the original shows as a PDF") {
			if case let .portableDocument(document)? = page.original?.state {
				document.pageCount == 1
			} else {
				false
			}
		}

		page.select(.reader(.text))
		try await waitUntil("the extracted text shows") {
			if case let .text(text)? = page.text?.state {
				text.contains("Rechnung Nummer 5 für Haftpflichtversicherung.")
			} else {
				false
			}
		}
		await controller.gateway.shutdown()
	}

	@MainActor
	private static func listedRows(_ library: LibraryViewController) -> [DocumentRow] {
		guard case let .documents(sections) = library.state else {
			return []
		}
		return sections.flatMap(\.rows)
	}

	private static func archiveAddress() throws -> String {
		try XCTUnwrap(
			ProcessInfo.processInfo.environment["SCHUBLADE_SCRIPTED_ARCHIVE"],
			"The check script passes the scripted archive's address"
		)
	}

	/// Follows the library until its copy holds at least `count` documents. After 30 seconds it shuts
	/// the core down, which ends the waiting read, because a read in Rust ignores cancellation.
	@MainActor
	private static func awaitDocuments(_ count: UInt64, in gateway: ApplicationGateway) async throws -> LibraryStatus {
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

	/// Adds one archived document to the scripted archive.
	private static func addDocument() async throws {
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

/// A condition a test waited for that did not arrive.
struct ConditionNotReached: Error {
	let expectation: String
	let detail: String
}

/// Polls `condition` on the main actor until it holds, for at most 30 seconds.
@MainActor
func waitUntil(_ expectation: String, condition: () -> Bool) async throws {
	let deadline = ContinuousClock.now + .seconds(30)
	while !condition() {
		guard ContinuousClock.now < deadline else {
			throw ConditionNotReached(expectation: expectation, detail: "not within 30 seconds")
		}
		try await Task.sleep(for: .milliseconds(50))
	}
}
