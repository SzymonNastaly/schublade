import AppKit
import ApplicationBindings

/// Pure AppKit connection form shown until an archive is configured.
final class ConnectionFormViewController: NSViewController, NSTextFieldDelegate {
	private let commands: any ApplicationCommands
	private let addressField = NSTextField()
	private let tokenField = NSSecureTextField()
	private let submitButton = NSButton()
	private let progressIndicator = NSProgressIndicator()
	private let refusalLabel = NSTextField(wrappingLabelWithString: "")
	private var isConnecting = false

	init(commands: any ApplicationCommands) {
		self.commands = commands
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
		configureControls()
		configureLayout()
	}

	func controlTextDidChange(_: Notification) {
		if !refusalLabel.isHidden {
			refusalLabel.stringValue = ""
			refusalLabel.isHidden = true
		}
	}

	func control(
		_: NSControl,
		textView _: NSTextView,
		doCommandBy commandSelector: Selector
	) -> Bool {
		if commandSelector == #selector(NSResponder.insertNewline(_:)) {
			submitConnection()
			return true
		}
		return false
	}

	private func configureControls() {
		addressField.placeholderString = "https://archive.example.org"
		addressField.delegate = self
		addressField.setAccessibilityIdentifier(InterfaceIdentifier.connectionAddressField)

		tokenField.placeholderString = "API token"
		tokenField.delegate = self
		tokenField.setAccessibilityIdentifier(InterfaceIdentifier.connectionTokenField)

		submitButton.title = "Connect"
		submitButton.bezelStyle = .rounded
		submitButton.keyEquivalent = "\r"
		submitButton.target = self
		submitButton.action = #selector(submitConnection)
		submitButton.setAccessibilityIdentifier(InterfaceIdentifier.connectionSubmitButton)

		progressIndicator.style = .spinning
		progressIndicator.controlSize = .small
		progressIndicator.isDisplayedWhenStopped = false

		refusalLabel.textColor = .systemRed
		refusalLabel.isHidden = true
		refusalLabel.isSelectable = true
		refusalLabel.setAccessibilityIdentifier(InterfaceIdentifier.connectionRefusalLabel)

		addressField.nextKeyView = tokenField
		tokenField.nextKeyView = submitButton
	}

	private func configureLayout() {
		let titleLabel = NSTextField(labelWithString: "Connect to Schublade")
		titleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .regular) + 6)

		let instructionLabel = NSTextField(
			wrappingLabelWithString: "Enter the address of your Schublade archive and an API token from Settings."
		)
		instructionLabel.textColor = .secondaryLabelColor

		let addressCaption = NSTextField(labelWithString: "Archive Address")
		addressCaption.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

		let tokenCaption = NSTextField(labelWithString: "API Token")
		tokenCaption.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

		let actionRow = NSStackView(views: [submitButton, progressIndicator])
		actionRow.orientation = .horizontal
		actionRow.alignment = .centerY
		actionRow.spacing = 10

		let formStack = NSStackView(views: [
			titleLabel,
			instructionLabel,
			addressCaption,
			addressField,
			tokenCaption,
			tokenField,
			actionRow,
			refusalLabel,
		])
		formStack.orientation = .vertical
		formStack.alignment = .leading
		formStack.spacing = 8
		formStack.setCustomSpacing(4, after: titleLabel)
		formStack.setCustomSpacing(16, after: instructionLabel)
		formStack.setCustomSpacing(4, after: addressCaption)
		formStack.setCustomSpacing(12, after: addressField)
		formStack.setCustomSpacing(4, after: tokenCaption)
		formStack.setCustomSpacing(14, after: tokenField)
		formStack.setCustomSpacing(10, after: actionRow)
		formStack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(formStack)

		NSLayoutConstraint.activate([
			formStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			formStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
			formStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
			formStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
			formStack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
			formStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
			addressField.widthAnchor.constraint(equalTo: formStack.widthAnchor),
			tokenField.widthAnchor.constraint(equalTo: formStack.widthAnchor),
			instructionLabel.widthAnchor.constraint(equalTo: formStack.widthAnchor),
			refusalLabel.widthAnchor.constraint(equalTo: formStack.widthAnchor),
		])
	}

	@objc private func submitConnection() {
		guard !isConnecting else {
			return
		}

		let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

		if address.isEmpty {
			showRefusal("Enter the address of your Schublade archive, such as https://archive.example.org.")
			return
		}
		if token.isEmpty {
			showRefusal("Paste an API token from your archive's Settings.")
			return
		}

		isConnecting = true
		updateControlsForConnectionState()

		Task {
			await performConnect(address: address, token: token)
		}
	}

	private func performConnect(address: String, token: String) async {
		defer {
			isConnecting = false
			updateControlsForConnectionState()
		}
		do {
			_ = try await commands.connectArchive(address: address, token: token)
			tokenField.stringValue = ""
		} catch {
			showRefusal(Self.refusalSentence(for: error))
		}
	}

	private func updateControlsForConnectionState() {
		addressField.isEnabled = !isConnecting
		tokenField.isEnabled = !isConnecting
		submitButton.isEnabled = !isConnecting
		if isConnecting {
			refusalLabel.stringValue = ""
			refusalLabel.isHidden = true
			progressIndicator.startAnimation(nil)
		} else {
			progressIndicator.stopAnimation(nil)
		}
	}

	private func showRefusal(_ message: String) {
		refusalLabel.stringValue = message
		refusalLabel.isHidden = false
	}

	private static func refusalSentence(for refusal: ConnectionRefusal) -> String {
		switch refusal {
		case .AddressInvalid:
			"This is not an archive address. Copy the address from your browser, such as https://archive.example.org."
		case .TokenRefused:
			"Schublade refused this token. Check that you copied all of it and that it was not revoked."
		case .TokenInsufficient:
			"This token cannot read or add documents. Issue another token in Settings."
		case .ArchiveUnreachable:
			"The archive could not be reached. Check the address and your internet connection."
		case .ArchiveUnavailable:
			"The archive is busy right now. Try again in a few minutes."
		case .ArchiveFailed:
			"The archive had a problem answering. Try again in a few minutes."
		case .NotAnArchive:
			"This address answers, but not like a Schublade archive. Check that it is the address of your archive."
		case .ArchiveOutdated:
			"This archive does not support the desktop application yet. Update your archive first."
		case let .ArchiveDiffers(connectedHost):
			"This Mac already collects folders into \(connectedHost)."
		case let .CredentialStorageFailed(detail):
			"The token could not be saved in the Keychain: \(detail)"
		case let .Application(fault):
			applicationFaultSentence(fault)
		}
	}

	private static func applicationFaultSentence(_ fault: ApplicationFault) -> String {
		switch fault {
		case .Stopped:
			"Schublade stopped before it could connect."
		case let .StoreFailed(detail):
			"Schublade could not save its local state: \(detail)"
		case let .Unexpected(detail):
			"Schublade encountered an unexpected error: \(detail)"
		}
	}
}
