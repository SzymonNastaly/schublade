import AppKit
import ApplicationBindings
import ApplicationPresentation

/// Trailing inspector pane showing resolved document details, clickable scope links and tag chips,
/// summary, and file facts.
final class DocumentInspectorViewController: NSViewController {
	private let onSelectScope: (NamedScope) -> Void
	private let onOpenInBrowser: (URL) -> Void

	private let scrollView = NSScrollView()
	private let documentContentView = FlippedClipDocumentView()
	private let stackView = NSStackView()
	private let emptyLabel = NSTextField(labelWithString: "No Document Selected")

	private var currentPresentation: DocumentDetailPresentation?
	private var archivePageURL: URL?

	init(
		onSelectScope: @escaping (NamedScope) -> Void,
		onOpenInBrowser: @escaping (URL) -> Void
	) {
		self.onSelectScope = onSelectScope
		self.onOpenInBrowser = onOpenInBrowser
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		configureViews()
		render(nil)
	}

	/// Shows a document's details. While a selected document's details are read, it shows nothing
	/// rather than "No Document Selected", which a walk through the list would flash at every step.
	func render(_ presentation: DocumentDetailPresentation?, hasSelection: Bool = false) {
		emptyLabel.isHidden = presentation != nil || hasSelection
		guard presentation != currentPresentation || (presentation == nil && stackView.arrangedSubviews.isEmpty) else {
			return
		}
		currentPresentation = presentation
		archivePageURL = presentation?.archivePageURL

		for arranged in stackView.arrangedSubviews {
			stackView.removeArrangedSubview(arranged)
			arranged.removeFromSuperview()
		}

		guard let presentation else {
			scrollView.isHidden = true
			return
		}
		scrollView.isHidden = false
		populateSections(from: presentation)
	}

	private func configureViews() {
		stackView.orientation = .vertical
		stackView.alignment = .leading
		stackView.spacing = 12
		stackView.translatesAutoresizingMaskIntoConstraints = false

		documentContentView.translatesAutoresizingMaskIntoConstraints = false
		documentContentView.addSubview(stackView)

		scrollView.documentView = documentContentView
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = true
		scrollView.backgroundColor = .windowBackgroundColor
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.setAccessibilityIdentifier(InterfaceIdentifier.inspectorScrollView)

		emptyLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
		emptyLabel.textColor = .secondaryLabelColor
		emptyLabel.alignment = .center
		emptyLabel.translatesAutoresizingMaskIntoConstraints = false

		view.addSubview(scrollView)
		view.addSubview(emptyLabel)

		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: view.topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			documentContentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
			stackView.topAnchor.constraint(equalTo: documentContentView.topAnchor, constant: 16),
			stackView.leadingAnchor.constraint(equalTo: documentContentView.leadingAnchor, constant: 14),
			stackView.trailingAnchor.constraint(equalTo: documentContentView.trailingAnchor, constant: -14),
			stackView.bottomAnchor.constraint(lessThanOrEqualTo: documentContentView.bottomAnchor, constant: -16),
			emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
		])
	}

	private func populateSections(from presentation: DocumentDetailPresentation) {
		if !presentation.detailRows.isEmpty {
			stackView.addArrangedSubview(sectionHeading("Details"))
			for row in presentation.detailRows {
				let rowView = InspectorFieldRowView(row: row, onSelectScope: onSelectScope)
				stackView.addArrangedSubview(rowView)
				rowView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
			}
		}

		if !presentation.tags.isEmpty {
			stackView.addArrangedSubview(sectionSeparator())
			stackView.addArrangedSubview(sectionHeading("Tags"))
			let flowView = WrappingFlowView()
			flowView.setViews(presentation.tags.map { tag in
				TagChipButton(tagScope: tag, onSelectScope: onSelectScope)
			})
			stackView.addArrangedSubview(flowView)
			flowView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
		}

		if let summary = presentation.summary {
			stackView.addArrangedSubview(sectionSeparator())
			stackView.addArrangedSubview(sectionHeading("Summary"))
			let summaryField = NSTextField(wrappingLabelWithString: summary)
			summaryField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
			summaryField.isSelectable = true
			summaryField.setAccessibilityIdentifier(InterfaceIdentifier.inspectorSummaryLabel)
			stackView.addArrangedSubview(summaryField)
			summaryField.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
		}

		populateFileSection(facts: presentation.fileFacts, hasBrowserURL: presentation.archivePageURL != nil)
	}

	private func populateFileSection(facts: [InspectorFileFact], hasBrowserURL: Bool) {
		stackView.addArrangedSubview(sectionSeparator())
		stackView.addArrangedSubview(sectionHeading("File"))
		for fact in facts {
			let rowView = InspectorFieldRowView(
				row: InspectorDetailRow(label: fact.label, displayValue: fact.value, copyValue: nil, linkedScope: nil),
				onSelectScope: onSelectScope
			)
			stackView.addArrangedSubview(rowView)
			rowView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
		}
		if hasBrowserURL {
			let browserButton = NSButton(
				title: "Open in Browser",
				target: self,
				action: #selector(openInBrowserPressed)
			)
			browserButton.bezelStyle = .rounded
			browserButton.controlSize = .small
			browserButton.setAccessibilityIdentifier(InterfaceIdentifier.inspectorOpenInBrowserButton)
			stackView.addArrangedSubview(browserButton)
		}
	}

	private func sectionHeading(_ title: String) -> NSTextField {
		let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .bold)
		let label = NSTextField(labelWithAttributedString: NSAttributedString(
			string: title.uppercased(),
			attributes: [.kern: 0.6, .font: font, .foregroundColor: InterfacePalette.selectionEdge]
		))
		label.setAccessibilityLabel(title)
		return label
	}

	private func sectionSeparator() -> NSBox {
		let separator = NSBox()
		separator.boxType = .separator
		separator.widthAnchor.constraint(equalToConstant: 220).isActive = true
		return separator
	}

	@objc private func openInBrowserPressed() {
		guard let archivePageURL else {
			return
		}
		onOpenInBrowser(archivePageURL)
	}
}
