import UIKit

/// Starts the core once per process and hands each scene the one controller.
public final class ApplicationDelegate: UIResponder, UIApplicationDelegate {
	let controller = ApplicationController(environment: .current())
	private(set) lazy var libraryRefresh = LibraryBackgroundRefresh(
		controller: controller,
		bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.schublade.iphone"
	)

	public func application(
		_: UIApplication,
		didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
	) -> Bool {
		controller.launch()
		libraryRefresh.register()
		return true
	}

	/// The system launched the application for answers of a background session, its own, which
	/// `launch` created, or the share extension's, which the submissions create for these events.
	public func application(
		_: UIApplication,
		handleEventsForBackgroundURLSession identifier: String,
		completionHandler: @escaping () -> Void
	) {
		controller.submissions.handleBackgroundEvents(session: identifier) {
			completionHandler()
		}
	}

	public func application(
		_: UIApplication,
		configurationForConnecting connectingSceneSession: UISceneSession,
		options _: UIScene.ConnectionOptions
	) -> UISceneConfiguration {
		let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
		configuration.delegateClass = SceneDelegate.self
		return configuration
	}
}
