import AppKit
import ApplicationBindings

/// Pure AppKit connection form shown until a readable archive is configured or while replacing a
/// refused token.
final class ConnectionFormViewController: NSViewController, NSTextFieldDelegate {
	private let commands: any ApplicationCommands
	private let initialAddress: String?
	private let instructionText: String
	private let onCancel: (() -> Void)?

	private let addressField = NSTextField()
	private let tokenField = NSSecureTextField()
	private let submitButton = NSButton()
	private let cancelButton = NSButton()
	private let progressIndicator = NSProgressIndicator()
	private let refusalLabel = NSTextField(wrappingLabelWithString: "")
	private var isConnecting = false
	private var hasConnected = false

	init(
		commands: any ApplicationCommands,
		initialAddress: String? = nil,
		instruction: String? = nil,
		onCancel: (() -> Void)? = nil
	) {
		self.commands = commands
		self.initialAddress = initialAddress
		instructionText = instruction
			?? "Enter the address of your Schublade archive and an API token from Settings."
		self.onCancel = onCancel
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
		if let initialAddress {
			addressField.stringValue = initialAddress
		}
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

		cancelButton.title = "Cancel"
		cancelButton.bezelStyle = .rounded
		cancelButton.keyEquivalent = "\u{1b}"
		cancelButton.target = self
		cancelButton.action = #selector(cancelConnection)
		cancelButton.isHidden = onCancel == nil
		cancelButton.setAccessibilityIdentifier(InterfaceIdentifier.connectionCancelButton)

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

		let instructionLabel = NSTextField(wrappingLabelWithString: instructionText)
		instructionLabel.textColor = .secondaryLabelColor

		let addressCaption = NSTextField(labelWithString: "Archive Address")
		addressCaption.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

		let tokenCaption = NSTextField(labelWithString: "API Token")
		tokenCaption.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

		var actionViews: [NSView] = [submitButton]
		if onCancel != nil {
			actionViews.append(cancelButton)
		}
		actionViews.append(progressIndicator)
		let actionRow = NSStackView(views: actionViews)
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
		activateFormConstraints(formStack: formStack, instructionLabel: instructionLabel)
	}

	private func activateFormConstraints(formStack: NSStackView, instructionLabel: NSTextField) {
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

	@objc private func cancelConnection() {
		guard !isConnecting, !hasConnected else {
			return
		}
		onCancel?()
	}

	@objc private func submitConnection() {
		guard !isConnecting, !hasConnected else {
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
		do {
			_ = try await commands.connectArchive(address: address, token: token)
			hasConnected = true
			tokenField.stringValue = ""
			isConnecting = false
			updateControlsForConnectionState()
		} catch {
			isConnecting = false
			updateControlsForConnectionState()
			showRefusal(Self.refusalSentence(for: error))
		}
	}

	private func updateControlsForConnectionState() {
		let controlsEnabled = !isConnecting && !hasConnected
		addressField.isEnabled = controlsEnabled
		tokenField.isEnabled = controlsEnabled
		submitButton.isEnabled = controlsEnabled
		cancelButton.isEnabled = controlsEnabled
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
			ApplicationFailureWording.faultSentence(fault)
		}
	}
}
