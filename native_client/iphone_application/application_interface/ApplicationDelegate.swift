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
