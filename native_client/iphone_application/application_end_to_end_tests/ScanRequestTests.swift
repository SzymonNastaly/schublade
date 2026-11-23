import ScanRequest
import UIKit
import VisionKit
import XCTest
@testable import ApplicationInterface

/// A scan requested from outside the application, in the window of the application that hosts the
/// tests, because its screen answers every request of the process.
final class ScanRequestTests: XCTestCase {
	/// A request made on the welcome screen is dropped, because a camera that opened once the person
	/// had connected would answer a request made long before. The Scan Document control tapped again
	/// while the camera shows, as a person may do, is taken at once, so closing the camera does not
	/// open it again.
	@MainActor
	func testARequestOpensTheCameraOnlyFromTheLibraryAndOnlyOnce() async throws {
		let controller = try XCTUnwrap((UIApplication.shared.delegate as? ApplicationDelegate)?.controller)
		let root = try XCTUnwrap(
			UIApplication.shared.connectedScenes
				.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
				.first
		)
		let address = try XCTUnwrap(ProcessInfo.processInfo.environment["SCHUBLADE_SCRIPTED_ARCHIVE"])
		try await waitUntil("the welcome screen shows") {
			if case let .running(status) = controller.situation, case .notConfigured = status.archive {
				true
			} else {
				false
			}
		}

		ScanRequestCenter.shared.request()
		try await waitUntil("the request on the welcome screen is dropped") { !ScanRequestCenter.shared.isPending }
		_ = await controller.connect(address: address, token: "scripted-end-to-end-token")
		try await waitUntil("sending is permitted") { controller.sendingPermitted }
		try await Task.sleep(for: .seconds(1))
		XCTAssertNil(root.presentedViewController)

		ScanRequestCenter.shared.request()
		try await waitUntil("the camera shows") { root.presentedViewController is VNDocumentCameraViewController }
		ScanRequestCenter.shared.request()
		try await waitUntil("the second request is taken") { !ScanRequestCenter.shared.isPending }
		await withCheckedContinuation { closed in
			root.presentedViewController?.dismiss(animated: true) {
				closed.resume()
			}
		}
		try await Task.sleep(for: .seconds(1))

		XCTAssertNil(root.presentedViewController)
	}
}
