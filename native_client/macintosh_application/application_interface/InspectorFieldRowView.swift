import AppKit
import ApplicationBindings
import ApplicationPresentation

/// One inspector row pairing a small label, a selectable or linked value, and a hover copy control.
final class InspectorFieldRowView: NSView {
	private let labelField = NSTextField(labelWithString: "")
	private let valueField = NSTextField(wrappingLabelWithString: "")
	private let linkButton = NSButton()
	private let copyButton = NSButton()

	private let row: InspectorDetailRow
	private let onSelectScope: (NamedScope) -> Void
	private var hoverTrackingArea: NSTrackingArea?
	private var resetCopySymbolTask: Task<Void, Never>?

	init(row: InspectorDetailRow, onSelectScope: @escaping (NamedScope) -> Void) {
		self.row = row
		self.onSelectScope = onSelectScope
		super.init(frame: .zero)
		configureViews()
		configureLayout()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let existing = hoverTrackingArea {
			removeTrackingArea(existing)
		}
		guard row.copyValue != nil else {
			return
		}
		let area = NSTrackingArea(
			rect: bounds,
			options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
			owner: self,
			userInfo: nil
		)
		addTrackingArea(area)
		hoverTrackingArea = area
	}

	override func mouseEntered(with _: NSEvent) {
		if row.copyValue != nil {
			copyButton.isHidden = false
		}
	}

	override func mouseExited(with _: NSEvent) {
		copyButton.isHidden = true
	}

	private func configureViews() {
		labelField.stringValue = row.label
		labelField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
		labelField.textColor = .secondaryLabelColor

		let identifierSlug = row.label.lowercased().replacingOccurrences(of: " ", with: "_")
		if row.linkedScope != nil {
			linkButton.title = row.displayValue
			linkButton.isBordered = false
			linkButton.alignment = .left
			linkButton.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
			linkButton.contentTintColor = InterfacePalette.link
			linkButton.lineBreakMode = .byTruncatingTail
			linkButton.target = self
			linkButton.action = #selector(linkPressed)
			linkButton.setAccessibilityIdentifier("inspector.field.\(identifierSlug)")
			valueField.isHidden = true
		} else {
			valueField.stringValue = row.displayValue
			valueField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
			valueField.isSelectable = true
			valueField.setAccessibilityIdentifier("inspector.field.\(identifierSlug)")
			linkButton.isHidden = true
		}

		copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy \(row.label)")
		copyButton.isBordered = false
		copyButton.bezelStyle = .accessoryBarAction
		copyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
		copyButton.contentTintColor = .secondaryLabelColor
		copyButton.toolTip = "Copy \(row.label)"
		copyButton.target = self
		copyButton.action = #selector(copyValuePressed)
		copyButton.isHidden = true
		copyButton.setContentHuggingPriority(.required, for: .horizontal)
		copyButton.setAccessibilityIdentifier("inspector.copy.\(identifierSlug)")
	}

	private func configureLayout() {
		let valueView: NSView = row.linkedScope != nil ? linkButton : valueField
		let valueRow = NSStackView(views: [valueView, copyButton])
		valueRow.orientation = .horizontal
		valueRow.alignment = .centerY
		valueRow.spacing = 6

		let stack = NSStackView(views: [labelField, valueRow])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 2
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)

		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
			valueRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
		])
	}

	@objc private func linkPressed() {
		guard let scope = row.linkedScope else {
			return
		}
		onSelectScope(scope)
	}

	@objc private func copyValuePressed() {
		guard let value = row.copyValue else {
			return
		}
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)

		copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
		copyButton.contentTintColor = .controlAccentColor
		resetCopySymbolTask?.cancel()
		resetCopySymbolTask = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(1200))
			guard let self, !Task.isCancelled else {
				return
			}
			copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
			copyButton.contentTintColor = .secondaryLabelColor
		}
	}
}
