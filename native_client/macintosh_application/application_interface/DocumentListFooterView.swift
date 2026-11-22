import AppKit

/// Bottom search bar shown beneath the document list for narrower search scopes or partial text
/// indexing.
final class DocumentListFooterView: NSView {
	private let topSeparator = NSBox()
	private let searchAllButton = NSButton()
	private let indexingLabel = NSTextField(wrappingLabelWithString: "")
	private var onSearchAllDocuments: (() -> Void)?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		configureControls()
		configureLayout()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func render(
		showsSearchAllDocuments: Bool,
		indexingNotice: String?,
		onSearchAllDocuments: @escaping () -> Void
	) {
		self.onSearchAllDocuments = onSearchAllDocuments
		searchAllButton.isHidden = !showsSearchAllDocuments
		if let indexingNotice {
			indexingLabel.stringValue = indexingNotice
			indexingLabel.isHidden = false
		} else {
			indexingLabel.stringValue = ""
			indexingLabel.isHidden = true
		}
		isHidden = !showsSearchAllDocuments && indexingNotice == nil
	}

	private func configureControls() {
		topSeparator.boxType = .separator
		topSeparator.translatesAutoresizingMaskIntoConstraints = false

		searchAllButton.title = "Search All Documents"
		searchAllButton.bezelStyle = .rounded
		searchAllButton.controlSize = .small
		searchAllButton.target = self
		searchAllButton.action = #selector(searchAllPressed)
		searchAllButton.isHidden = true
		searchAllButton.setAccessibilityIdentifier(InterfaceIdentifier.documentListFooterSearchAll)

		indexingLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		indexingLabel.textColor = .secondaryLabelColor
		indexingLabel.alignment = .center
		indexingLabel.isHidden = true
		indexingLabel.setAccessibilityIdentifier(InterfaceIdentifier.documentListFooterIndexing)
	}

	private func configureLayout() {
		let stack = NSStackView(views: [searchAllButton, indexingLabel])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false

		addSubview(topSeparator)
		addSubview(stack)

		NSLayoutConstraint.activate([
			topSeparator.topAnchor.constraint(equalTo: topAnchor),
			topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
			topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 8),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
			indexingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 290),
		])
	}

	@objc private func searchAllPressed() {
		onSearchAllDocuments?()
	}
}
