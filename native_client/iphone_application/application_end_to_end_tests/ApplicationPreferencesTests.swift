import Foundation
import XCTest
@testable import ApplicationInterface

/// What the application remembers of a person's choices from one start to the next.
final class ApplicationPreferencesTests: XCTestCase {
	/// Keep Originals starts at 500 MB, and a choice, No Limit included, is what the next start reads.
	@MainActor
	func testAChosenStorageLimitIsKeptForTheNextStart() throws {
		let suite = "org.schublade.iphone.preferences-tests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		XCTAssertEqual(ApplicationPreferences(defaults: defaults).originalStorageLimit, 500_000_000)
		ApplicationPreferences(defaults: defaults).originalStorageLimit = 2_000_000_000
		XCTAssertEqual(ApplicationPreferences(defaults: defaults).originalStorageLimit, 2_000_000_000)
		ApplicationPreferences(defaults: defaults).originalStorageLimit = nil
		XCTAssertNil(ApplicationPreferences(defaults: defaults).originalStorageLimit)
	}
}
