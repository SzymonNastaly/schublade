import UIKit

/// Gives the one window the root view controller.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
	var window: UIWindow?

	func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
		guard let windowScene = scene as? UIWindowScene,
		      let delegate = UIApplication.shared.delegate as? ApplicationDelegate
		else {
			return
		}
		let window = UIWindow(windowScene: windowScene)
		window.rootViewController = UINavigationController(
			rootViewController: LibraryStateViewController(controller: delegate.controller)
		)
		window.makeKeyAndVisible()
		self.window = window
	}
}
