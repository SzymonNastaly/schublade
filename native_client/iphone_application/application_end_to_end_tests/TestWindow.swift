import UIKit
import XCTest

/// A window of its own in the host application's scene, so a page presents its sheets and pushes
/// as it does on the screen. `close` gives the key window back to the host.
final class TestWindow: UIWindow {
	private weak var previousKey: UIWindow?

	private init(windowScene: UIWindowScene, previousKey: UIWindow?) {
		self.previousKey = previousKey
		super.init(windowScene: windowScene)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("A test window is built in code")
	}

	@MainActor
	static func showing(_ root: UIViewController) throws -> TestWindow {
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
		let window = TestWindow(windowScene: scene, previousKey: scene.keyWindow)
		window.rootViewController = root
		window.makeKeyAndVisible()
		return window
	}

	func close() {
		rootViewController?.presentedViewController?.dismiss(animated: false)
		isHidden = true
		previousKey?.makeKey()
	}
}
