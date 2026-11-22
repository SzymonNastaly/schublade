import Observation

/// A scan requested from outside the application: the Scan Document intent, which Shortcuts, Siri,
/// the Action button, and the Control Center and Lock Screen controls run, or the Home Screen quick
/// action. The request waits until the submissions screen shows, which presents the document camera,
/// so a request that starts the application is not lost while the core starts.
@Observable
public final class ScanRequestCenter {
	public static let shared = ScanRequestCenter()

	/// The type of the Home Screen quick action, as the Info.plist's UIApplicationShortcutItems names it.
	public static let quickActionType = "scan-document"

	public private(set) var isPending = false

	public func request() {
		isPending = true
	}

	/// Answers whether a request was pending, and clears it.
	public func take() -> Bool {
		defer { isPending = false }
		return isPending
	}
}
