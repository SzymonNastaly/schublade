import ApplicationBindings
import Foundation
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
