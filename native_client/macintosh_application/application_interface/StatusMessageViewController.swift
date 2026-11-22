import AppKit

/// Centered plain text message screen used while starting, stopped, or unavailable.
final class StatusMessageViewController: NSViewController {
	private let message: String
	private let labelIdentifier: String

	init(message: String, identifier: String) {
		self.message = message
		labelIdentifier = identifier
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		let label = NSTextField(wrappingLabelWithString: message)
		label.alignment = .center
		label.textColor = .secondaryLabelColor
		label.translatesAutoresizingMaskIntoConstraints = false
		label.setAccessibilityIdentifier(labelIdentifier)
		view.addSubview(label)

		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
			label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
			label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
			label.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
		])
	}
}
