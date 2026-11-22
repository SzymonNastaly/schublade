import AppKit

/// Centered plain text message screen used while starting, stopped, or unavailable.
public final class StatusMessageViewController: NSViewController {
	private let message: String
	private let detail: String?
	private let labelIdentifier: String

	public init(message: String, detail: String? = nil, identifier: String) {
		self.message = message
		self.detail = detail
		labelIdentifier = identifier
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override public func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
	}

	override public func viewDidLoad() {
		super.viewDidLoad()

		let label = NSTextField(wrappingLabelWithString: message)
		label.alignment = .center
		label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular) + 2, weight: .medium)
		label.textColor = .labelColor
		label.setAccessibilityIdentifier(labelIdentifier)

		var views: [NSView] = [label]
		if let detail, !detail.isEmpty {
			let detailLabel = NSTextField(wrappingLabelWithString: detail)
			detailLabel.alignment = .center
			detailLabel.textColor = .secondaryLabelColor
			views.append(detailLabel)
		}

		let stack = NSStackView(views: views)
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 8
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)

		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
			stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
			stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
		])
	}
}
