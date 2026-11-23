import Foundation

/// What the application remembers of a person's choices: the room the downloaded originals may
/// take, which the core receives at every start because it keeps no choice of its own, and whether
/// a document's details show when its page opens.
final class ApplicationPreferences {
	private static let originalStorageLimitKey = "originalStorageLimit"
	private static let detailsShownKey = "document.detailsShown"

	private let defaults: UserDefaults

	init(defaults: UserDefaults) {
		self.defaults = defaults
	}

	/// The most bytes the downloaded originals may take, or nil for no limit, which is stored as 0.
	var originalStorageLimit: UInt64? {
		get {
			guard defaults.object(forKey: Self.originalStorageLimitKey) != nil else {
				return IphoneDevice.defaultOriginalStorageLimit
			}
			let stored = defaults.integer(forKey: Self.originalStorageLimitKey)
			return stored <= 0 ? nil : UInt64(stored)
		}
		set {
			defaults.set(Int(clamping: newValue ?? 0), forKey: Self.originalStorageLimitKey)
		}
	}

	/// Whether the details sheet shows when a page opens, as the Mac's inspector remembers whether it
	/// is shown. Opening the sheet sets it and closing it clears it.
	var detailsShown: Bool {
		get { defaults.object(forKey: Self.detailsShownKey) as? Bool ?? true }
		set { defaults.set(newValue, forKey: Self.detailsShownKey) }
	}
}
