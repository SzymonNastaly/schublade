import AppKit
import ApplicationPresentation
import LibraryPresentation

/// One item cell in the sidebar with leading symbol, title, and trailing count or status icon.
final class SidebarItemCellView: NSTableCellView {
	private let symbolView = NSImageView()
	private let titleField = NSTextField(labelWithString: "")
	private let countField = NSTextField(labelWithString: "")
	private let accessorySymbolView = NSImageView()

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		configureViews()
		configureLayout()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func configure(with presentation: SidebarItemPresentation) {
		symbolView.image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: nil)
		symbolView.contentTintColor = Self.sectionColor(of: presentation.kind)
		titleField.stringValue = presentation.title
		setAccessibilityIdentifier("sidebarItem.\(presentation.id)")

		switch presentation.accessory {
		case .none:
			countField.isHidden = true
			accessorySymbolView.isHidden = true
		case let .count(text):
			countField.stringValue = text
			countField.isHidden = false
			accessorySymbolView.isHidden = true
		case let .symbol(name, tone):
			countField.isHidden = true
			accessorySymbolView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
			accessorySymbolView.contentTintColor = tintColor(for: tone)
			accessorySymbolView.isHidden = false
		}
	}

	private func configureViews() {
		symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
		symbolView.setContentHuggingPriority(.required, for: .horizontal)
		symbolView.setContentCompressionResistancePriority(.required, for: .horizontal)

		titleField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
		titleField.lineBreakMode = .byTruncatingTail
		titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		countField.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
		countField.textColor = .secondaryLabelColor
		countField.alignment = .right
		countField.setContentHuggingPriority(.required, for: .horizontal)
		countField.setContentCompressionResistancePriority(.required, for: .horizontal)

		accessorySymbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
		accessorySymbolView.setContentHuggingPriority(.required, for: .horizontal)
		accessorySymbolView.setContentCompressionResistancePriority(.required, for: .horizontal)
	}

	private func configureLayout() {
		let stack = NSStackView(views: [symbolView, titleField, countField, accessorySymbolView])
		stack.orientation = .horizontal
		stack.alignment = .centerY
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)

		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			symbolView.widthAnchor.constraint(equalToConstant: 18),
		])
	}

	private func tintColor(for tone: StatusLineTone) -> NSColor {
		switch tone {
		case .normal:
			.secondaryLabelColor
		case .active:
			InterfacePalette.archive
		case .attention:
			InterfacePalette.attention
		}
	}

	/// The website's section colours: blue for the archive, orange for what needs attention, and
	/// green for the folders on this Mac.
	private static func sectionColor(of kind: SidebarItemKind) -> NSColor {
		switch kind {
		case .destination(.library):
			InterfacePalette.archive
		case .destination(.needsAttention):
			InterfacePalette.attention
		case .destination(.folder), .addFolder:
			InterfacePalette.collector
		}
	}
}
