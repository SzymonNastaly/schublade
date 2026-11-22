import AppKit
import ApplicationPresentation

/// Centered empty-state view shown when a listing returns zero rows.
final class DocumentListEmptyView: NSView {
	private let titleLabel = NSTextField(labelWithString: "")
	private let detailLabel = NSTextField(wrappingLabelWithString: "")
	private let addFolderButton = NSButton()
	private let searchAllButton = NSButton()
	private var onAddFolder: (() -> Void)?
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
		_ presentation: EmptyListPresentation,
		onAddFolder: @escaping () -> Void,
		onSearchAllDocuments: @escaping () -> Void
	) {
		self.onAddFolder = onAddFolder
		self.onSearchAllDocuments = onSearchAllDocuments
		titleLabel.stringValue = presentation.title
		detailLabel.stringValue = presentation.detail
		addFolderButton.isHidden = !presentation.showsAddFolderButton
		searchAllButton.isHidden = !presentation.showsSearchAllDocumentsButton
	}

	private func configureControls() {
		titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular) + 2, weight: .semibold)
		titleLabel.alignment = .center
		titleLabel.setAccessibilityIdentifier(InterfaceIdentifier.documentListEmptyTitle)

		detailLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		detailLabel.textColor = .secondaryLabelColor
		detailLabel.alignment = .center
		detailLabel.setAccessibilityIdentifier(InterfaceIdentifier.documentListEmptyDetail)

		addFolderButton.title = "Add Folder…"
		addFolderButton.bezelStyle = .rounded
		addFolderButton.target = self
		addFolderButton.action = #selector(addFolderPressed)
		addFolderButton.isHidden = true
		addFolderButton.setAccessibilityIdentifier(InterfaceIdentifier.documentListEmptyAddFolder)

		searchAllButton.title = "Search All Documents"
		searchAllButton.bezelStyle = .rounded
		searchAllButton.target = self
		searchAllButton.action = #selector(searchAllPressed)
		searchAllButton.isHidden = true
		searchAllButton.setAccessibilityIdentifier(InterfaceIdentifier.documentListEmptySearchAll)
	}

	private func configureLayout() {
		let stack = NSStackView(views: [titleLabel, detailLabel, addFolderButton, searchAllButton])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 6
		stack.setCustomSpacing(12, after: detailLabel)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)

		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
			detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
		])
	}

	@objc private func addFolderPressed() {
		onAddFolder?()
	}

	@objc private func searchAllPressed() {
		onSearchAllDocuments?()
	}
}
