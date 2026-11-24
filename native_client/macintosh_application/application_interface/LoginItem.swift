import os
import ServiceManagement

/// Opening Schublade at login, through the system's `SMAppService.mainApp`. The system holds the
/// state, so it is read on each use; the isolated environment has an inert login item.
public final class LoginItem {
	private static let log = Logger(subsystem: "org.schublade.application", category: "login item")
	private let isInert: Bool

	/// A Debug build is inert too, so a development copy never starts at every login.
	public init(isInert: Bool) {
		#if DEBUG
		self.isInert = true
		#else
		self.isInert = isInert
		#endif
	}

	var isEnabled: Bool {
		!isInert && SMAppService.mainApp.status == .enabled
	}

	/// Answers whether the system took the change.
	@discardableResult
	func setEnabled(_ enabled: Bool) -> Bool {
		guard !isInert else {
			return false
		}
		do {
			if enabled {
				try SMAppService.mainApp.register()
			} else {
				try SMAppService.mainApp.unregister()
			}
			return true
		} catch {
			Self.log.error("The login item could not be changed: \(error.localizedDescription, privacy: .public)")
			return false
		}
	}
}
