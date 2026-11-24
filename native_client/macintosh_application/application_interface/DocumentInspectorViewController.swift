import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// The inspector, the place of a document's facts: its title and summary at the head, the facts a
/// person copies, the places it is filed under, its tags, and the file with the way to the browser.
final class DocumentInspectorViewController: NSViewController {
	private static let edgeInset: CGFloat = 16

	private let onSelectScope: (NamedScope) -> Void
	private let onOpenInBrowser: (URL) -> Void

	private let scrollView = NSScrollView()
	private let documentContentView = FlippedClipDocumentView()
	private let stackView = NSStackView()

	private var currentPresentation: InspectorPresentation?
	private var rows: [InspectorFieldRowView] = []

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

	/// Shows a document's details, and nothing without a document: the reader already says that none
	/// is selected, and a walk through the list would flash a second notice at every step.
	func render(_ presentation: InspectorPresentation?) {
		guard presentation != currentPresentation || (presentation == nil && stackView.arrangedSubviews.isEmpty) else {
			return
		}
		currentPresentation = presentation
		rows = []
		for arranged in stackView.arrangedSubviews {
			stackView.removeArrangedSubview(arranged)
			arranged.removeFromSuperview()
		}
		guard let presentation else {
			scrollView.isHidden = true
			return
		}
		scrollView.isHidden = false
		populate(from: presentation)
	}

	/// The rows, tags, and Open in Browser, in the order Tab reaches them.
	var keyViews: [NSView] {
		Self.buttons(in: stackView)
	}

	private static func buttons(in view: NSView) -> [NSView] {
		view.subviews.flatMap { $0 is NSButton ? [$0] : buttons(in: $0) }
	}

	/// Shows one row as it stands under the pointer and another as just copied, so the renderer can
	/// draw both states without a pointer or the pasteboard.
	func exhibitRows(underPointer hovered: String?, copied: String?) {
		for row in rows {
			if row.label == hovered {
				row.showPointer(inside: true)
			}
			if row.label == copied {
				row.showCopied()
			}
		}
	}

	private func configureViews() {
		stackView.orientation = .vertical
		stackView.alignment = .leading
		stackView.spacing = 2
		stackView.translatesAutoresizingMaskIntoConstraints = false

		documentContentView.translatesAutoresizingMaskIntoConstraints = false
		documentContentView.addSubview(stackView)

		scrollView.documentView = documentContentView
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = true
		scrollView.backgroundColor = .windowBackgroundColor
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.setAccessibilityIdentifier(InterfaceIdentifier.inspectorScrollView)

		view.addSubview(scrollView)

		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: view.topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			documentContentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
			stackView.topAnchor.constraint(equalTo: documentContentView.topAnchor, constant: Self.edgeInset),
			stackView.leadingAnchor.constraint(equalTo: documentContentView.leadingAnchor, constant: Self.edgeInset),
			stackView.trailingAnchor.constraint(
				equalTo: documentContentView.trailingAnchor,
				constant: -Self.edgeInset
			),
			stackView.bottomAnchor.constraint(
				lessThanOrEqualTo: documentContentView.bottomAnchor,
				constant: -Self.edgeInset
			),
		])
	}

	private func populate(from presentation: InspectorPresentation) {
		populateHead(from: presentation)

		if !presentation.facts.isEmpty, let head = stackView.arrangedSubviews.last {
			stackView.setCustomSpacing(14, after: head)
			for fact in presentation.facts {
				append(row: fact.copyValue.map { value in
					InspectorFieldRowView(
						label: fact.label,
						displayValue: fact.displayValue,
						behaviour: .copies(value),
						onSelectScope: onSelectScope
					)
				}, plain: fact)
			}
		}

		if !presentation.filedUnder.isEmpty {
			appendHeading("Filed Under")
			for place in presentation.filedUnder {
				append(row: place.linkedScope.map { scope in
					InspectorFieldRowView(
						label: place.label,
						displayValue: place.displayValue,
						behaviour: .leadsTo(scope),
						onSelectScope: onSelectScope
					)
				}, plain: place)
			}
		}

		if !presentation.tags.isEmpty {
			appendHeading("Tags")
			let flowView = WrappingFlowView()
			flowView.setViews(presentation.tags.map { tag in
				TagChipButton(tagScope: tag, onSelectScope: onSelectScope)
			})
			appendFullWidth(flowView)
		}

		appendHeading("File")
		for fact in presentation.fileFacts {
			append(row: nil, plain: InspectorDetailRow(
				label: fact.label,
				displayValue: fact.value,
				copyValue: nil,
				linkedScope: nil
			))
		}
		if presentation.archivePageURL != nil {
			appendBrowserButton()
		}
	}

	private func populateHead(from presentation: InspectorPresentation) {
		let title = NSTextField(wrappingLabelWithString: presentation.title)
		title.font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .semibold)
		title.isSelectable = true
		title.setAccessibilityIdentifier(InterfaceIdentifier.inspectorTitleLabel)
		appendFullWidth(title)
		stackView.setCustomSpacing(4, after: title)

		if let summary = presentation.summary {
			let summaryField = Self.secondaryText(summary, style: .body)
			summaryField.isSelectable = true
			summaryField.setAccessibilityIdentifier(InterfaceIdentifier.inspectorSummaryLabel)
			appendFullWidth(summaryField)
			stackView.setCustomSpacing(4, after: summaryField)
		}
		appendFullWidth(Self.secondaryText(presentation.fileLine, style: .subheadline))
	}

	/// A row that acts on a click, or a plain label over its value. A row reaches past the column by
	/// its fill's inset, so its text stands in line with the head's.
	private func append(row: InspectorFieldRowView?, plain detail: InspectorDetailRow) {
		guard let row else {
			let label = Self.secondaryText(detail.label, style: .subheadline)
			let value = NSTextField(wrappingLabelWithString: detail.displayValue)
			value.font = NSFont.monospacedDigitSystemFont(
				ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
				weight: .regular
			)
			value.isSelectable = true
			let pair = NSStackView(views: [label, value])
			pair.orientation = .vertical
			pair.alignment = .leading
			pair.spacing = 1
			pair.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
			appendFullWidth(pair)
			return
		}
		rows.append(row)
		let holder = NSView()
		row.translatesAutoresizingMaskIntoConstraints = false
		holder.addSubview(row)
		NSLayoutConstraint.activate([
			row.topAnchor.constraint(equalTo: holder.topAnchor),
			row.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
			row.leadingAnchor.constraint(
				equalTo: holder.leadingAnchor,
				constant: -InspectorFieldRowView.horizontalInset
			),
			row.trailingAnchor.constraint(
				equalTo: holder.trailingAnchor,
				constant: InspectorFieldRowView.horizontalInset
			),
		])
		appendFullWidth(holder)
	}

	private func appendHeading(_ title: String) {
		if let last = stackView.arrangedSubviews.last {
			stackView.setCustomSpacing(20, after: last)
		}
		let heading = NSTextField(labelWithString: title)
		heading.font = NSFont.systemFont(
			ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
			weight: .semibold
		)
		heading.textColor = .secondaryLabelColor
		stackView.addArrangedSubview(heading)
		stackView.setCustomSpacing(6, after: heading)
	}

	private func appendBrowserButton() {
		let button = NSButton(title: "Open in Browser", target: self, action: #selector(openInBrowserPressed))
		button.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
		button.imagePosition = .imageLeading
		button.bezelStyle = .push
		button.setAccessibilityIdentifier(InterfaceIdentifier.inspectorOpenInBrowserButton)
		if let last = stackView.arrangedSubviews.last {
			stackView.setCustomSpacing(14, after: last)
		}
		stackView.addArrangedSubview(button)
		stackView.setCustomSpacing(6, after: button)
		appendFullWidth(Self.secondaryText(InspectorPresentation.browserSentence, style: .footnote))
	}

	private func appendFullWidth(_ view: NSView) {
		stackView.addArrangedSubview(view)
		view.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
	}

	@objc private func openInBrowserPressed() {
		currentPresentation?.archivePageURL.map(onOpenInBrowser)
	}

	private static func secondaryText(_ text: String, style: NSFont.TextStyle) -> NSTextField {
		let field = NSTextField(wrappingLabelWithString: text)
		field.font = NSFont.preferredFont(forTextStyle: style)
		field.textColor = .secondaryLabelColor
		return field
	}
}
