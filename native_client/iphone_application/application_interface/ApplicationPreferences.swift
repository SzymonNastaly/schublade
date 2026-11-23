import Foundation

/// What the application remembers of a person's choices: the room the downloaded originals may
/// take, which the core receives at every start because it keeps no choice of its own.
final class ApplicationPreferences {
	/// 500 MB, the second of `IphoneDevice.wording.storageLimitChoices`.
	static let defaultOriginalStorageLimit: UInt64 = 500_000_000
	private static let originalStorageLimitKey = "originalStorageLimit"

	private let defaults: UserDefaults

	init(defaults: UserDefaults) {
		self.defaults = defaults
	}

	/// The most bytes the downloaded originals may take, or nil for no limit, which is stored as 0.
	var originalStorageLimit: UInt64? {
		get {
			guard defaults.object(forKey: Self.originalStorageLimitKey) != nil else {
				return Self.defaultOriginalStorageLimit
			}
			let stored = defaults.integer(forKey: Self.originalStorageLimitKey)
			return stored <= 0 ? nil : UInt64(stored)
		}
		set {
			defaults.set(Int(clamping: newValue ?? 0), forKey: Self.originalStorageLimitKey)
		}
	}
}
