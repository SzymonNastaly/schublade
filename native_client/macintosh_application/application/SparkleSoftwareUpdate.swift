import AppKit
import ApplicationInterface
import Sparkle

/// Sparkle's updater over the appcast that `SUFeedURL` names on schublade.org. It checks once a day,
/// downloads a release whose EdDSA signature matches `SUPublicEDKey`, and installs it when the
/// application quits, or at once when the person chooses Install and Relaunch.
final class SparkleSoftwareUpdate: NSObject, SoftwareUpdate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
	weak var applicationDelegate: ApplicationDelegate?
	private var updaterController: SPUStandardUpdaterController?

	func start() {
		updaterController = SPUStandardUpdaterController(
			startingUpdater: true,
			updaterDelegate: self,
			userDriverDelegate: self
		)
	}

	func checkForUpdates() {
		// The menu bar item leaves the application inactive, and Sparkle's window would open behind
		// the front application.
		NSApp.activate()
		updaterController?.checkForUpdates(nil)
	}

	func updaterWillRelaunchApplication(_: SPUUpdater) {
		applicationDelegate?.prepareForUpdateRelaunch()
	}

	/// The application lives in the menu bar, so a scheduled check that finds an update shows it
	/// without taking the person away from the application in front.
	var supportsGentleScheduledUpdateReminders: Bool {
		true
	}
}
