import ApplicationPresentation
import Foundation

/// What the application remembers about a person's choices: whether the login item was ever
/// established, the quit alert's "do not ask again", and the scope and document the window showed
/// last. The isolated environment keeps them in a suite of its own, emptied as it opens, so a test
/// never reads an installed application's preferences or what an earlier test left.
public final class ApplicationPreferences {
	private static let loginItemEstablishedKey = "loginItemEstablished"
	private static let quitAlertSuppressedKey = "quitAlertSuppressed"
	private static let originalStorageLimitKey = "originalStorageLimit"
	private static let libraryPlaceKey = "libraryPlace"
	/// Two gigabytes, the design's default room for downloaded originals.
	static let defaultOriginalStorageLimit: UInt64 = 2_000_000_000

	private let defaults: UserDefaults

	public init(isolated: Bool) {
		let isolatedSuite = "org.schublade.isolated.\(ProcessInfo.processInfo.processIdentifier)"
		guard isolated, let suite = UserDefaults(suiteName: isolatedSuite) else {
			defaults = .standard
			return
		}
		suite.removePersistentDomain(forName: isolatedSuite)
		defaults = suite
	}

	var loginItemEstablished: Bool {
		get { defaults.bool(forKey: Self.loginItemEstablishedKey) }
		set { defaults.set(newValue, forKey: Self.loginItemEstablishedKey) }
	}

	/// The most bytes the downloaded originals may take, or nil for no limit.
	var originalStorageLimit: UInt64? {
		get {
			guard defaults.object(forKey: Self.originalStorageLimitKey) != nil else {
				return Self.defaultOriginalStorageLimit
			}
			let stored = defaults.integer(forKey: Self.originalStorageLimitKey)
			return stored <= 0 ? nil : UInt64(stored)
		}
		set { defaults.set(Int(clamping: newValue ?? 0), forKey: Self.originalStorageLimitKey) }
	}

	/// The scope and document the window showed last.
	var libraryPlace: RememberedLibraryPlace? {
		get {
			(defaults.dictionary(forKey: Self.libraryPlaceKey) as? [String: String])
				.flatMap(RememberedLibraryPlace.init(storedValues:))
		}
		set { defaults.set(newValue?.storedValues, forKey: Self.libraryPlaceKey) }
	}

	var quitAlertSuppressed: Bool {
		get { defaults.bool(forKey: Self.quitAlertSuppressedKey) }
		set { defaults.set(newValue, forKey: Self.quitAlertSuppressedKey) }
	}
}
