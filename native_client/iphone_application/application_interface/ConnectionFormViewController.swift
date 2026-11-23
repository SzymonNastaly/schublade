import UIKit
import UniformTypeIdentifiers

/// The first screen a person sees: the icon, what Schublade does, and the archive's address and a
/// token, as the website's Settings issues one. Pushed from Settings with the connected archive's
/// address filled in, the same form replaces the token.
final class ConnectionFormViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
	enum Purpose: Equatable {
		/// No archive is connected yet. Once one is, the root screen shows the library.
		case firstConnection
		/// Replaces the token of the archive at this origin, or moves to another archive.
		case tokenReplacement(origin: String)
	}

	private enum FormRow {
		case address
		case token
		case connect
	}

	private static let sections: [[FormRow]] = [[.address, .token], [.connect]]

	private let controller: ApplicationController
	private let purpose: Purpose
	private let connected: () -> Void
	private let addressField = UITextField()
	private let tokenField = TokenField()
	private let pasteControl: UIPasteControl = {
		let configuration = UIPasteControl.Configuration()
		configuration.displayMode = .labelOnly
		configuration.cornerStyle = .capsule
		return UIPasteControl(configuration: configuration)
	}()

	private let connectButton = UIButton(configuration: .filled())
	/// The sentence of the last refusal, which replaces the form's footer until the next attempt.
	private var refusal: String?
	private var connecting = false

	private lazy var collectionView: UICollectionView = {
		let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
			var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
			configuration.headerMode = index == 0 && self?.purpose == .firstConnection ? .supplementary : .none
			configuration.footerMode = index == 0 ? .supplementary : .none
			let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
			if index == 1 {
				section.contentInsets.top = 8
			}
			return section
		}
		return UICollectionView(frame: .zero, collectionViewLayout: layout)
	}()

	private lazy var cellRegistration = UICollectionView
		.CellRegistration<UICollectionViewListCell, FormRow> { [weak self] cell, _, row in
			self?.configure(cell, row: row)
		}

	private let headerRegistration = UICollectionView.SupplementaryRegistration<WelcomeHeaderView>(
		elementKind: UICollectionView.elementKindSectionHeader
	) { _, _, _ in }

	private let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
		elementKind: UICollectionView.elementKindSectionFooter
	) { _, _, _ in }

	init(controller: ApplicationController, purpose: Purpose, connected: @escaping () -> Void = {}) {
		self.controller = controller
		self.purpose = purpose
		self.connected = connected
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		if case .tokenReplacement = purpose {
			title = "Replace Token"
			navigationItem.largeTitleDisplayMode = .never
		}
		view.backgroundColor = .systemGroupedBackground
		configureFields()
		showPasteControl()
		for name in [UIApplication.didBecomeActiveNotification, UIPasteboard.changedNotification] {
			NotificationCenter.default.addObserver(self, selector: #selector(showPasteControl), name: name, object: nil)
		}
		connectButton.configuration?.title = "Connect"
		connectButton.configuration?.cornerStyle = .large
		connectButton.configuration?.buttonSize = .large
		connectButton.accessibilityIdentifier = "welcome.connect"
		connectButton.addAction(UIAction { [weak self] _ in self?.connect() }, for: .primaryActionTriggered)

		// A registration made during the first dequeue fails an assertion.
		_ = cellRegistration
		collectionView.dataSource = self
		collectionView.delegate = self
		collectionView.keyboardDismissMode = .interactive
		collectionView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(collectionView)
		// The form ends above the keyboard, so Connect can scroll into view under the token.
		view.keyboardLayoutGuide.usesBottomSafeArea = false
		NSLayoutConstraint.activate([
			collectionView.topAnchor.constraint(equalTo: view.topAnchor),
			collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			collectionView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
		])
	}

	/// Paste shows while the pasteboard holds text, which a person copied in the browser and brings
	/// back by returning to Schublade. Asking whether it holds text does not read it.
	@objc private func showPasteControl() {
		let hidden = !UIPasteboard.general.hasStrings
		if pasteControl.isHidden != hidden {
			pasteControl.isHidden = hidden
		}
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		placeFirstScreen()
	}

	/// The first screen's content sits a little above the middle of the space while it fits, as a
	/// welcome does, and moves to the top when the keyboard leaves it less room.
	private func placeFirstScreen() {
		guard purpose == .firstConnection else {
			return
		}
		let insets = collectionView.safeAreaInsets
		let room = collectionView.bounds.height - insets.top - insets.bottom
		let content = collectionView.collectionViewLayout.collectionViewContentSize.height
		let top = max(0, ((room - content) * 0.4).rounded(.down))
		if collectionView.contentInset.top != top {
			collectionView.contentInset.top = top
		}
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		if case .tokenReplacement = purpose, tokenField.text?.isEmpty ?? true {
			tokenField.becomeFirstResponder()
		}
	}

	private func configureFields() {
		for field in [addressField, tokenField] as [UITextField] {
			field.autocapitalizationType = .none
			field.autocorrectionType = .no
			field.spellCheckingType = .no
			field.font = .preferredFont(forTextStyle: .body)
			field.adjustsFontForContentSizeCategory = true
			field.clearButtonMode = .whileEditing
			field.delegate = self
		}
		addressField.placeholder = "https://archive.example.org"
		addressField.keyboardType = .URL
		addressField.textContentType = .URL
		addressField.returnKeyType = .next
		addressField.accessibilityLabel = "Address"
		addressField.accessibilityIdentifier = "welcome.address"
		if case let .tokenReplacement(origin) = purpose {
			addressField.text = origin
		}
		tokenField.placeholder = "Required"
		tokenField.isSecureTextEntry = true
		// No content type, so the system does not offer to keep the token as a password.
		tokenField.textContentType = nil
		tokenField.returnKeyType = .go
		tokenField.accessibilityLabel = "Token"
		tokenField.accessibilityIdentifier = "welcome.token"
		tokenField.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier])
		pasteControl.target = tokenField
		pasteControl.accessibilityIdentifier = "welcome.paste"
	}

	// MARK: The list

	func numberOfSections(in _: UICollectionView) -> Int {
		Self.sections.count
	}

	func collectionView(_: UICollectionView, numberOfItemsInSection section: Int) -> Int {
		Self.sections[section].count
	}

	func collectionView(
		_ collectionView: UICollectionView,
		cellForItemAt indexPath: IndexPath
	) -> UICollectionViewCell {
		collectionView.dequeueConfiguredReusableCell(
			using: cellRegistration,
			for: indexPath,
			item: Self.sections[indexPath.section][indexPath.item]
		)
	}

	func collectionView(
		_ collectionView: UICollectionView,
		viewForSupplementaryElementOfKind kind: String,
		at indexPath: IndexPath
	) -> UICollectionReusableView {
		if kind == UICollectionView.elementKindSectionHeader {
			return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
		}
		let footer = collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
		footer.contentConfiguration = footerContent
		return footer
	}

	func collectionView(_: UICollectionView, shouldHighlightItemAt _: IndexPath) -> Bool {
		false
	}

	/// Where to issue a token, or why the archive refused the last one, in red.
	private var footerContent: UIListContentConfiguration {
		var content = UIListContentConfiguration.footer()
		if let refusal {
			content.text = refusal
			content.textProperties.color = .systemRed
		} else if case .tokenReplacement = purpose {
			content.text = "In your archive's Settings in the browser, issue a new token for this iPhone and paste it "
				+ "here. It takes the place of the old one."
		} else {
			content.text = "In your archive's Settings in the browser, issue a token for this iPhone and paste it here."
		}
		return content
	}

	private func configure(_ cell: UICollectionViewListCell, row: FormRow) {
		cell.backgroundConfiguration = row == .connect ? .clear() : cell.defaultBackgroundConfiguration()
		switch row {
		case .address:
			cell.host(FormFieldView(label: "Address", field: addressField, accessory: nil))
		case .token:
			cell.host(FormFieldView(label: "Token", field: tokenField, accessory: pasteControl))
		case .connect:
			cell.host(connectButton, fillingCell: true)
		}
	}

	// MARK: Connecting

	private func connect() {
		guard !connecting else {
			return
		}
		let address = (addressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let token = (tokenField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !address.isEmpty, !token.isEmpty else {
			refuse(address.isEmpty ? "Enter your archive's address." : "Enter the token.")
			return
		}
		view.endEditing(true)
		show(refusal: nil)
		setConnecting(true)
		Task {
			let refusal = await controller.connect(address: address, token: token)
			setConnecting(false)
			if let refusal {
				refuse(refusal)
			} else {
				// A secure field that leaves the screen holding text makes the system offer to save it as
				// a password, and the Keychain item of the core already keeps the token.
				tokenField.text = nil
				connected()
			}
		}
	}

	private func setConnecting(_ connecting: Bool) {
		self.connecting = connecting
		connectButton.configuration?.showsActivityIndicator = connecting
		connectButton.isUserInteractionEnabled = !connecting
		addressField.isEnabled = !connecting
		tokenField.isEnabled = !connecting
		pasteControl.isEnabled = !connecting
	}

	private func refuse(_ sentence: String) {
		show(refusal: sentence)
		Haptics.connectionRefused()
		UIAccessibility.post(notification: .announcement, argument: sentence)
	}

	private func show(refusal: String?) {
		guard refusal != self.refusal else {
			return
		}
		self.refusal = refusal
		let footer = collectionView.supplementaryView(
			forElementKind: UICollectionView.elementKindSectionFooter,
			at: IndexPath(item: 0, section: 0)
		) as? UICollectionViewListCell
		footer?.contentConfiguration = footerContent
		collectionView.collectionViewLayout.invalidateLayout()
	}
}

extension ConnectionFormViewController: UITextFieldDelegate {
	func textFieldDidBeginEditing(_ textField: UITextField) {
		// Connect stays in view under the field the keyboard rose for.
		guard textField === tokenField else {
			return
		}
		Task {
			try? await Task.sleep(for: .milliseconds(300))
			collectionView.scrollToItem(at: IndexPath(item: 0, section: 1), at: .bottom, animated: true)
		}
	}

	func textFieldShouldReturn(_ textField: UITextField) -> Bool {
		if textField === addressField {
			tokenField.becomeFirstResponder()
		} else {
			connect()
		}
		return true
	}
}
