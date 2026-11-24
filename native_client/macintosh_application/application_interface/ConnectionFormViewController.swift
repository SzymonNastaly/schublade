import AppKit
import ApplicationBindings
import ApplicationPresentation

/// The welcome, which connects the first archive under the application's icon, and the replace
/// form, the same form for a new token of the connected archive.
public final class ConnectionFormViewController: NSViewController, NSTextFieldDelegate {
	private static let formWidth: CGFloat = 420
	private static let iconSize: CGFloat = 96

	private let commands: any ApplicationCommands
	private let purpose: ConnectionFormPurpose
	private let onConnected: () -> Void
	private let onCancel: () -> Void

	private let addressField = NSTextField()
	private let tokenField = NSSecureTextField()
	private let submitButton = NSButton()
	private let cancelButton = NSButton()
	private let progressIndicator = NSProgressIndicator()
	private let noteLabel = NSTextField(wrappingLabelWithString: ConnectionFormPurpose.tokenNote)
	private let refusalSymbol = NSImageView()
	private let refusalLabel = NSTextField(wrappingLabelWithString: "")
	private lazy var refusalRow = NSStackView(views: [refusalSymbol, refusalLabel])
	private var isConnecting = false
	private var hasConnected = false
	private var columnTop: NSLayoutConstraint?

	public init(
		commands: any ApplicationCommands,
		purpose: ConnectionFormPurpose,
		onConnected: @escaping () -> Void = {},
		onCancel: @escaping () -> Void = {}
	) {
		self.commands = commands
		self.purpose = purpose
		self.onConnected = onConnected
		self.onCancel = onCancel
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
		configureControls()
		configureLayout()
	}

	/// The column hangs from a top placed once, from its height with the note, so a refusal longer
	/// than the note grows it downward and nothing above it moves.
	override public func viewDidLayout() {
		super.viewDidLayout()
		guard let columnTop, columnTop.constant == 0, let column = columnTop.firstItem as? NSView else {
			return
		}
		columnTop.constant = -(column.frame.height / 2).rounded() - 16
	}

	override public func viewDidAppear() {
		super.viewDidAppear()
		// The replace form knows the address, so the token is what a person types first.
		view.window?.makeFirstResponder(purpose.address == nil ? addressField : tokenField)
	}

	/// Shows a refusal without connecting, for the offscreen renderer.
	public func exhibitRefusal(address: String, refusal: ConnectionRefusal) {
		loadViewIfNeeded()
		addressField.stringValue = address
		tokenField.stringValue = "exhibited-token"
		showRefusal(ApplicationFailureWording.connectionRefusalSentence(refusal))
	}

	public func controlTextDidChange(_: Notification) {
		showRefusal(nil)
	}

	public func control(
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

	private func configureLayout() {
		let column = NSStackView()
		column.orientation = .vertical
		column.alignment = .centerX
		column.spacing = 0

		if purpose == .welcome {
			let iconView = NSImageView(image: NSApp.applicationIconImage)
			iconView.imageScaling = .scaleProportionallyUpOrDown
			iconView.setAccessibilityElement(false)
			NSLayoutConstraint.activate([
				iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
				iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
			])
			column.addArrangedSubview(iconView)
			column.setCustomSpacing(16, after: iconView)
		}

		let titleLabel = NSTextField(labelWithString: purpose.title)
		titleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .title1).pointSize)
		column.addArrangedSubview(titleLabel)
		column.setCustomSpacing(24, after: titleLabel)

		if let sentence = purpose.sentence {
			let sentenceLabel = NSTextField(wrappingLabelWithString: sentence)
			sentenceLabel.font = NSFont.preferredFont(forTextStyle: .body)
			sentenceLabel.textColor = .secondaryLabelColor
			sentenceLabel.alignment = .center
			column.setCustomSpacing(8, after: titleLabel)
			column.addArrangedSubview(sentenceLabel)
			column.setCustomSpacing(24, after: sentenceLabel)
			sentenceLabel.widthAnchor.constraint(equalToConstant: Self.formWidth + 20).isActive = true
		}

		let grid = makeFormGrid()
		column.addArrangedSubview(grid)
		column.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(column)

		let top = column.topAnchor.constraint(equalTo: view.centerYAnchor)
		columnTop = top
		NSLayoutConstraint.activate([
			column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			top,
			grid.widthAnchor.constraint(equalToConstant: Self.formWidth),
		])
	}

	@objc private func cancelConnection() {
		guard !isConnecting, !hasConnected else {
			return
		}
		onCancel()
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
			showRefusal("Paste a token from your archive's Settings.")
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
			onConnected()
		} catch {
			isConnecting = false
			updateControlsForConnectionState()
			showRefusal(ApplicationFailureWording.connectionRefusalSentence(error))
		}
	}

	private func updateControlsForConnectionState() {
		let controlsEnabled = !isConnecting && !hasConnected
		addressField.isEnabled = controlsEnabled
		tokenField.isEnabled = controlsEnabled
		submitButton.isEnabled = controlsEnabled
		cancelButton.isEnabled = controlsEnabled
		if isConnecting {
			showRefusal(nil)
			progressIndicator.startAnimation(nil)
		} else {
			progressIndicator.stopAnimation(nil)
		}
	}

	/// A refusal takes the place of the note under the token field, and VoiceOver reads it out.
	private func showRefusal(_ sentence: String?) {
		let refused = sentence != nil
		guard refused || !refusalLabel.isHidden else {
			return
		}
		refusalLabel.stringValue = sentence ?? ""
		refusalLabel.isHidden = !refused
		refusalRow.isHidden = !refused
		noteLabel.isHidden = refused
		if let sentence {
			NSAccessibility.post(
				element: refusalLabel,
				notification: .announcementRequested,
				userInfo: [
					.announcement: sentence,
					.priority: NSAccessibilityPriorityLevel.high.rawValue,
				]
			)
		}
	}
}

private extension ConnectionFormViewController {
	func configureControls() {
		addressField.placeholderString = "https://archive.example.org"
		addressField.stringValue = purpose.address ?? ""
		addressField.delegate = self
		addressField.setAccessibilityIdentifier(InterfaceIdentifier.connectionAddressField)

		tokenField.placeholderString = "Required"
		tokenField.delegate = self
		tokenField.setAccessibilityIdentifier(InterfaceIdentifier.connectionTokenField)

		submitButton.title = "Connect"
		submitButton.bezelStyle = .push
		submitButton.controlSize = .large
		submitButton.keyEquivalent = "\r"
		submitButton.target = self
		submitButton.action = #selector(submitConnection)
		submitButton.setAccessibilityIdentifier(InterfaceIdentifier.connectionSubmitButton)

		cancelButton.title = "Cancel"
		cancelButton.bezelStyle = .push
		cancelButton.controlSize = .large
		cancelButton.keyEquivalent = "\u{1b}"
		cancelButton.target = self
		cancelButton.action = #selector(cancelConnection)
		cancelButton.setAccessibilityIdentifier(InterfaceIdentifier.connectionCancelButton)

		progressIndicator.style = .spinning
		progressIndicator.controlSize = .small
		progressIndicator.isDisplayedWhenStopped = false

		let noteFont = NSFont.preferredFont(forTextStyle: .subheadline)
		noteLabel.font = noteFont
		noteLabel.textColor = .secondaryLabelColor

		// The system's red measures 3.55:1 as text on white, so the symbol carries it and the
		// sentence stays in the label colour.
		refusalSymbol.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
		refusalSymbol.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .subheadline)
		refusalSymbol.contentTintColor = .systemRed
		refusalSymbol.setContentHuggingPriority(.required, for: .horizontal)
		refusalLabel.font = noteFont
		refusalLabel.textColor = .labelColor
		refusalLabel.isSelectable = true
		refusalLabel.setAccessibilityIdentifier(InterfaceIdentifier.connectionRefusalLabel)
		showRefusal(nil)

		addressField.nextKeyView = tokenField
		tokenField.nextKeyView = purpose.cancellable ? cancelButton : submitButton
		cancelButton.nextKeyView = submitButton
	}

	/// The Mac's form: labels at the trailing edge of the first column, the fields in the second,
	/// and the note, then the buttons, under the fields.
	func makeFormGrid() -> NSGridView {
		let addressLabel = NSTextField(labelWithString: "Address:")
		let tokenLabel = NSTextField(labelWithString: "Token:")
		refusalRow.orientation = .horizontal
		refusalRow.alignment = .top
		refusalRow.spacing = 5
		let notes = NSStackView(views: [noteLabel, refusalRow])
		notes.orientation = .vertical
		notes.alignment = .leading
		notes.spacing = 0
		notes.detachesHiddenViews = true

		var buttons: [NSView] = [progressIndicator]
		if purpose.cancellable {
			buttons.append(cancelButton)
		}
		buttons.append(submitButton)
		let buttonRow = NSStackView(views: buttons)
		buttonRow.orientation = .horizontal
		buttonRow.spacing = 12
		if purpose.cancellable {
			buttonRow.setCustomSpacing(8, after: cancelButton)
		}

		let grid = NSGridView(views: [
			[addressLabel, addressField],
			[tokenLabel, tokenField],
			[NSGridCell.emptyContentView, notes],
			[NSGridCell.emptyContentView, buttonRow],
		])
		grid.rowSpacing = 10
		grid.columnSpacing = 8
		grid.rowAlignment = .firstBaseline
		grid.column(at: 0).xPlacement = .trailing
		grid.column(at: 1).xPlacement = .fill
		grid.row(at: 2).topPadding = -4
		grid.row(at: 3).topPadding = 10
		grid.cell(for: buttonRow)?.xPlacement = .trailing
		grid.cell(for: notes)?.rowAlignment = .none
		return grid
	}
}
