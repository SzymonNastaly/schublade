import Observation

/// A scan requested from outside the application: the Scan Document intent, which Shortcuts, Siri,
/// the Action button, and the Control Center and Lock Screen controls run, or the Home Screen quick
/// action. The request waits while the core starts, so a request that starts the application is not
/// lost. The library screen takes it and presents the document camera, and any other screen drops it.
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
