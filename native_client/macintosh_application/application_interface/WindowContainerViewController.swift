import AppKit

/// Persistent root content view controller that swaps child screens without resizing `NSWindow`.
final class WindowContainerViewController: NSViewController {
	private var currentChild: NSViewController?

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 1340, height: 820))
	}

	func display(_ child: NSViewController) {
		if let currentChild {
			currentChild.view.removeFromSuperview()
			currentChild.removeFromParent()
		}

		addChild(child)
		let childView = child.view
		childView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(childView)
		NSLayoutConstraint.activate([
			childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			childView.topAnchor.constraint(equalTo: view.topAnchor),
			childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])
		currentChild = child
	}
}
