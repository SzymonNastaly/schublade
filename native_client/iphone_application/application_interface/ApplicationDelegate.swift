import UIKit

/// Starts the core once per process and hands each scene the one controller.
public final class ApplicationDelegate: UIResponder, UIApplicationDelegate {
	let controller = ApplicationController(environment: .current())

	public func application(
		_: UIApplication,
		didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
	) -> Bool {
		controller.launch()
		return true
	}

	/// The system launched the application for answers of the background session, which the
	/// session delivers once `launch` has created it.
	public func application(
		_: UIApplication,
		handleEventsForBackgroundURLSession _: String,
		completionHandler: @escaping () -> Void
	) {
		controller.submissions.handleBackgroundEvents {
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
