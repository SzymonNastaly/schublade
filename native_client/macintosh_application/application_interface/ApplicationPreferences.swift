import Foundation

/// What the application remembers about a person's choices: whether the login item was ever
/// established, and the quit alert's "do not ask again". The isolated environment keeps them in a
/// suite of its own, so a test never reads or writes an installed application's preferences.
final class ApplicationPreferences {
	private static let loginItemEstablishedKey = "loginItemEstablished"
	private static let quitAlertSuppressedKey = "quitAlertSuppressed"

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

	var quitAlertSuppressed: Bool {
		get { defaults.bool(forKey: Self.quitAlertSuppressedKey) }
		set { defaults.set(newValue, forKey: Self.quitAlertSuppressedKey) }
	}
}
