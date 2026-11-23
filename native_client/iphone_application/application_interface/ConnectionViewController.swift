import UIKit

/// The archive's address and a token, as the website's Settings issues one. Opened from the library
/// with the connected archive's address, it replaces a token the archive refused.
final class ConnectionViewController: UIViewController, UITextFieldDelegate {
	private let controller: ApplicationController
	private let replacedAddress: String?
	private let connected: () -> Void
	private let addressField = UITextField()
	private let tokenField = UITextField()
	private let connectButton = UIButton(configuration: .filled())
	private let refusalLabel = UILabel()

	init(controller: ApplicationController, replacingAt address: String? = nil, connected: @escaping () -> Void = {}) {
		self.controller = controller
		replacedAddress = address
		self.connected = connected
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		title = replacedAddress == nil ? "Connect" : "Replace Token"
		navigationItem.largeTitleDisplayMode = .always
		navigationController?.navigationBar.prefersLargeTitles = true
		view.backgroundColor = .systemGroupedBackground

		let instruction = UILabel()
		instruction.text = "Enter your archive's address and a token that reads and adds documents. "
			+ "Issue the token in Settings of your archive in the browser."
		instruction.font = .preferredFont(forTextStyle: .subheadline)
		instruction.textColor = .secondaryLabel
		instruction.numberOfLines = 0

		configure(addressField, placeholder: "https://archive.example.org")
		addressField.keyboardType = .URL
		addressField.textContentType = .URL
		addressField.returnKeyType = .next
		addressField.text = replacedAddress
		configure(tokenField, placeholder: "Token")
		tokenField.isSecureTextEntry = true
		// No content type, so the system does not offer to keep the token as a password.
		tokenField.textContentType = nil
		tokenField.returnKeyType = .go

		connectButton.configuration?.title = "Connect"
		connectButton.configuration?.cornerStyle = .large
		connectButton.configuration?.buttonSize = .large
		connectButton.addAction(UIAction { [weak self] _ in self?.connect() }, for: .primaryActionTriggered)

		refusalLabel.font = .preferredFont(forTextStyle: .footnote)
		refusalLabel.textColor = .systemRed
		refusalLabel.numberOfLines = 0

		let stack = UIStackView(arrangedSubviews: [instruction, addressField, tokenField, connectButton, refusalLabel])
		stack.axis = .vertical
		stack.spacing = 16
		stack.setCustomSpacing(24, after: tokenField)
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
			stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
		])
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		if replacedAddress != nil {
			tokenField.becomeFirstResponder()
		}
	}

	private func configure(_ field: UITextField, placeholder: String) {
		field.placeholder = placeholder
		field.borderStyle = .roundedRect
		field.autocapitalizationType = .none
		field.autocorrectionType = .no
		field.font = .preferredFont(forTextStyle: .body)
		field.adjustsFontForContentSizeCategory = true
		field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
		field.delegate = self
	}

	func textFieldShouldReturn(_ textField: UITextField) -> Bool {
		if textField === addressField {
			tokenField.becomeFirstResponder()
		} else {
			connect()
		}
		return true
	}

	private func connect() {
		let address = (addressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let token = (tokenField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !address.isEmpty, !token.isEmpty else {
			refusalLabel.text = "Enter both the address and the token."
			return
		}
		view.endEditing(true)
		refusalLabel.text = nil
		connectButton.configuration?.showsActivityIndicator = true
		connectButton.isEnabled = false
		Task {
			let refusal = await controller.connect(address: address, token: token)
			connectButton.configuration?.showsActivityIndicator = false
			connectButton.isEnabled = true
			refusalLabel.text = refusal
			if refusal == nil {
				connected()
			}
		}
	}
}
