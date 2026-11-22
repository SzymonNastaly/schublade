import os
import ServiceManagement

/// Opening Schublade at login, through the system's `SMAppService.mainApp`. The system holds the
/// state, so it is read on each use; the isolated environment has an inert login item.
final class LoginItem {
	private static let log = Logger(subsystem: "org.schublade.application", category: "login item")
	private let isInert: Bool

	init(isInert: Bool) {
		self.isInert = isInert
	}

	var isEnabled: Bool {
		!isInert && SMAppService.mainApp.status == .enabled
	}

	func setEnabled(_ enabled: Bool) {
		guard !isInert else {
			return
		}
		do {
			if enabled {
				try SMAppService.mainApp.register()
			} else {
				try SMAppService.mainApp.unregister()
			}
		} catch {
			Self.log.error("The login item could not be changed: \(error.localizedDescription, privacy: .public)")
		}
	}
}
