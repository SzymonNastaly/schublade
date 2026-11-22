import Foundation

/// What the application remembers about a person's choices: whether the login item was ever
/// established, and the quit alert's "do not ask again". The isolated environment keeps them in a
/// suite of its own, so a test never reads or writes an installed application's preferences.
final class ApplicationPreferences {
	private static let loginItemEstablishedKey = "loginItemEstablished"
	private static let quitAlertSuppressedKey = "quitAlertSuppressed"
	private static let originalStorageLimitKey = "originalStorageLimit"
	/// Two gigabytes, the design's default room for downloaded originals.
	static let defaultOriginalStorageLimit: UInt64 = 2_000_000_000

	private let defaults: UserDefaults

	init(isolated: Bool) {
		defaults = isolated
			? UserDefaults(suiteName: "org.schublade.isolated.\(ProcessInfo.processInfo.processIdentifier)") ??
			.standard
			: .standard
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

	var quitAlertSuppressed: Bool {
		get { defaults.bool(forKey: Self.quitAlertSuppressedKey) }
		set { defaults.set(newValue, forKey: Self.quitAlertSuppressedKey) }
	}
}
