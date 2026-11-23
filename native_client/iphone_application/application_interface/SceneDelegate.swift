import ScanRequest
import UIKit

/// Gives the one window the root view controller, and passes the Home Screen quick action on.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
	var window: UIWindow?

	func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options: UIScene.ConnectionOptions) {
		guard let windowScene = scene as? UIWindowScene,
		      let delegate = UIApplication.shared.delegate as? ApplicationDelegate
		else {
			return
		}
		// A quick action that started the application is a request before the first screen shows, so
		// that screen can be the library under the camera.
		if let shortcutItem = options.shortcutItem {
			_ = Self.perform(shortcutItem)
		}
		let window = UIWindow(windowScene: windowScene)
		window.rootViewController = RootViewController(controller: delegate.controller)
		window.makeKeyAndVisible()
		self.window = window
	}

	func windowScene(
		_: UIWindowScene,
		performActionFor shortcutItem: UIApplicationShortcutItem,
		completionHandler: @escaping (Bool) -> Void
	) {
		completionHandler(Self.perform(shortcutItem))
	}

	private static func perform(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
		guard shortcutItem.type == ScanRequestCenter.quickActionType else {
			return false
		}
		ScanRequestCenter.shared.request()
		return true
	}

	func sceneDidBecomeActive(_: UIScene) {
		(UIApplication.shared.delegate as? ApplicationDelegate)?.controller.becameActive()
	}

	func sceneWillResignActive(_: UIScene) {
		(UIApplication.shared.delegate as? ApplicationDelegate)?.controller.resignedActive()
	}

	func sceneDidEnterBackground(_: UIScene) {
		(UIApplication.shared.delegate as? ApplicationDelegate)?.controller.enteredBackground()
	}
}
