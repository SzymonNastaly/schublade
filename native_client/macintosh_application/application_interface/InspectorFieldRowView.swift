import AppKit
import ApplicationBindings
import LibraryPresentation

/// One row of the inspector that a click acts on, a label over its value. A fact copies its value
/// and says "Copied" for a second; a place the document is filed under lists that place's
/// documents. The trailing symbol says which before the click: `doc.on.doc` under the pointer, or
/// a chevron that always shows. As a button it takes the keyboard focus, and Space presses it.
final class InspectorFieldRowView: NSButton {
	enum Behaviour {
		case copies(String)
		case leadsTo(NamedScope)
	}

	/// How far the fill reaches past the text on each side.
	static let horizontalInset: CGFloat = 6
	private static let verticalInset: CGFloat = 4
	private static let cornerRadius: CGFloat = 6
	private static let copiedDuration: Duration = .seconds(1)

	let label: String
	let displayValue: String
	private let behaviour: Behaviour
	private let onSelectScope: (NamedScope) -> Void

	private let labelField = NSTextField(labelWithString: "")
	private let valueField = NSTextField(wrappingLabelWithString: "")
	private let trailingSymbol = NSImageView()
	private var hoverArea: NSTrackingArea?
	private var pointerInside = false
	private var copiedReset: Task<Void, Never>?
	private(set) var showsCopied = false

	init(label: String, displayValue: String, behaviour: Behaviour, onSelectScope: @escaping (NamedScope) -> Void) {
		self.label = label
		self.displayValue = displayValue
		self.behaviour = behaviour
		self.onSelectScope = onSelectScope
		super.init(frame: .zero)
		title = ""
		isBordered = false
		imagePosition = .noImage
		setButtonType(.momentaryChange)
		wantsLayer = true
		target = self
		action = #selector(pressed)
		configureViews()
		configureLayout()
		configureAccessibility()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
	}

	/// The labels are drawings inside the button, so a click on them is a click on the row.
	override func hitTest(_ point: NSPoint) -> NSView? {
		super.hitTest(point) == nil ? nil : self
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let hoverArea {
			removeTrackingArea(hoverArea)
		}
		let area = NSTrackingArea(
			rect: .zero,
			options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
			owner: self,
			userInfo: nil
		)
		addTrackingArea(area)
		hoverArea = area
	}

	override func mouseEntered(with _: NSEvent) {
		showPointer(inside: true)
	}

	override func mouseExited(with _: NSEvent) {
		showPointer(inside: false)
	}

	override func draw(_: NSRect) {
		guard pointerInside || isHighlighted else {
			return
		}
		(isHighlighted ? NSColor.tertiarySystemFill : NSColor.quaternarySystemFill).setFill()
		NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
	}

	override var focusRingMaskBounds: NSRect {
		bounds
	}

	override func drawFocusRingMask() {
		NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
	}

	/// Shows the row as it stands under the pointer, as the renderer does without one.
	func showPointer(inside: Bool) {
		pointerInside = inside
		updateTrailingSymbol()
		needsDisplay = true
	}

	/// Shows "Copied" in place of the value for a second, without touching the pasteboard.
	func showCopied() {
		copiedReset?.cancel()
		setCopied(true)
		copiedReset = Task { [weak self] in
			try? await Task.sleep(for: Self.copiedDuration)
			guard !Task.isCancelled else {
				return
			}
			self?.setCopied(false)
		}
	}

	@objc private func pressed() {
		switch behaviour {
		case let .copies(value):
			copyValue(value)
		case let .leadsTo(scope):
			onSelectScope(scope)
		}
	}

	@objc private func copyFromMenu() {
		if case let .copies(value) = behaviour {
			copyValue(value)
		}
	}

	private func copyValue(_ value: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
		showCopied()
		NSAccessibility.post(
			element: self,
			notification: .announcementRequested,
			userInfo: [
				.announcement: "Copied",
				.priority: NSAccessibilityPriorityLevel.high.rawValue,
			]
		)
	}

	private func setCopied(_ copied: Bool) {
		guard copied != showsCopied else {
			return
		}
		showsCopied = copied
		let dissolve = CATransition()
		dissolve.type = .fade
		dissolve.duration = 0.15
		layer?.add(dissolve, forKey: "copiedDissolve")
		valueField.stringValue = copied ? "Copied" : displayValue
		valueField.textColor = copied ? InterfacePalette.archive : .labelColor
		updateTrailingSymbol()
	}

	private func updateTrailingSymbol() {
		switch behaviour {
		case .copies:
			let symbol = showsCopied ? "checkmark" : "doc.on.doc"
			trailingSymbol.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
			trailingSymbol.contentTintColor = showsCopied ? InterfacePalette.archive : .secondaryLabelColor
			trailingSymbol.isHidden = !(showsCopied || pointerInside)
		case .leadsTo:
			trailingSymbol.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
			trailingSymbol.contentTintColor = .tertiaryLabelColor
			trailingSymbol.isHidden = false
		}
	}

	private func configureViews() {
		labelField.stringValue = label
		labelField.font = NSFont.preferredFont(forTextStyle: .subheadline)
		labelField.textColor = .secondaryLabelColor

		valueField.stringValue = displayValue
		valueField.font = NSFont.monospacedDigitSystemFont(
			ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
			weight: .regular
		)
		valueField.textColor = .labelColor

		trailingSymbol.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .subheadline)
		trailingSymbol.setContentHuggingPriority(.required, for: .horizontal)
		trailingSymbol.setContentCompressionResistancePriority(.required, for: .horizontal)
		updateTrailingSymbol()

		if case .copies = behaviour {
			let contextMenu = NSMenu()
			let copyItem = NSMenuItem(title: "Copy", action: #selector(copyFromMenu), keyEquivalent: "")
			copyItem.target = self
			copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
			contextMenu.addItem(copyItem)
			menu = contextMenu
		}
	}

	private func configureLayout() {
		let texts = NSStackView(views: [labelField, valueField])
		texts.orientation = .vertical
		texts.alignment = .leading
		texts.spacing = 1
		for view in [texts, trailingSymbol] {
			view.translatesAutoresizingMaskIntoConstraints = false
			addSubview(view)
		}
		NSLayoutConstraint.activate([
			texts.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
			texts.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
			texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
			texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingSymbol.leadingAnchor, constant: -6),
			trailingSymbol.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
			trailingSymbol.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
	}

	private func configureAccessibility() {
		let labelIdentifier = label.lowercased().replacingOccurrences(of: " ", with: "_")
		setAccessibilityIdentifier("inspector.field.\(labelIdentifier)")
		for view in [labelField, valueField, trailingSymbol] {
			view.setAccessibilityElement(false)
		}
	}

	override func accessibilityLabel() -> String? {
		label
	}

	override func accessibilityValue() -> Any? {
		showsCopied ? "Copied" : displayValue
	}

	override func accessibilityHelp() -> String? {
		switch behaviour {
		case .copies: "Copies the value."
		case let .leadsTo(scope): "Shows the documents of \(scope.name)."
		}
	}
}
