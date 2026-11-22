import AppKit
import ApplicationBindings
import XCTest
@testable import ApplicationInterface

/// Xcode loads this bundle into the Debug application, which the scheme starts in the isolated
/// environment. XCTestCase is nonisolated, so the module keeps nonisolated default isolation.
final class ApplicationEndToEndTests: XCTestCase {
	@MainActor
	func testTheApplicationFollowsTheCollectorToAnEnrolledFolder() async throws {
		let delegate = try XCTUnwrap(NSApp.delegate as? ApplicationDelegate)
		let controller = delegate.controller
		XCTAssertEqual(controller.environment.collectorConfiguration.credentialStorage, .processMemory)
		try await waitUntil("the collector runs without an archive", controller) { status in
			status.archive == .notConfigured
		}
		XCTAssertNotNil(controller.statusItem.item.button)
		XCTAssertTrue(controller.statusItem.item.isVisible)

		let folder = URL.temporaryDirectory.appending(
			path: "schublade_end_to_end_\(UUID().uuidString)",
			directoryHint: .isDirectory
		)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
		addTeardownBlock {
			try FileManager.default.removeItem(at: folder)
		}
		// Without an archive no content is resolved, so the survey of a file cannot end.
		try Data("%PDF-1.7 a letter".utf8).write(to: folder.appending(path: "letter.pdf"))

		let enrolled = try await controller.commands.enrollFolder(root: folder.path(percentEncoded: false))
		try await waitUntil("the enrolled folder is surveying", controller) { status in
			status.folders.contains { listed in
				guard listed.folder == enrolled, case .surveying = listed.admission else {
					return false
				}
				return true
			}
		}
	}

	@MainActor
	private func waitUntil(
		_ expectation: String,
		_ controller: ApplicationController,
		_ condition: (CollectorStatus) -> Bool
	) async throws {
		let deadline = ContinuousClock.now + .seconds(30)
		while true {
			if case let .running(status) = controller.situation, condition(status) {
				return
			}
			guard ContinuousClock.now < deadline else {
				throw SituationNotReached(expectation: expectation, situation: String(describing: controller.situation))
			}
			try await Task.sleep(for: .milliseconds(50))
		}
	}
}

private struct SituationNotReached: Error, CustomStringConvertible {
	let expectation: String
	let situation: String

	var description: String {
		"Waited 30 seconds until \(expectation), but the situation is \(situation)"
	}
}
