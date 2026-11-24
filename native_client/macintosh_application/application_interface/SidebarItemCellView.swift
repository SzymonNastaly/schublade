import AppKit
import ApplicationPresentation
import LibraryPresentation

/// One item cell in the sidebar: a leading symbol, the title, and at the trailing edge a count,
/// a small spinner, or a symbol in the attention colour.
final class SidebarItemCellView: NSTableCellView {
	private let symbolView = NSImageView()
	private let titleField = NSTextField(labelWithString: "")
	private let countField = NSTextField(labelWithString: "")
	private let spinner = NSProgressIndicator()
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
		symbolView.contentTintColor = Self.symbolColor(of: presentation.kind)
		titleField.stringValue = presentation.title
		titleField.textColor = presentation.kind == .addFolder ? .secondaryLabelColor : .labelColor
		setAccessibilityIdentifier("sidebarItem.\(presentation.id)")

		countField.isHidden = true
		accessorySymbolView.isHidden = true
		spinner.isHidden = true
		spinner.stopAnimation(nil)
		switch presentation.accessory {
		case .none:
			break
		case let .count(text):
			countField.stringValue = text
			countField.isHidden = false
		case let .inProgress(description):
			spinner.setAccessibilityLabel(description)
			spinner.toolTip = description
			spinner.isHidden = false
			spinner.startAnimation(nil)
		case let .attention(symbolName, description):
			accessorySymbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
			accessorySymbolView.toolTip = description
			accessorySymbolView.isHidden = false
		}
	}

	private func configureViews() {
		symbolView.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
		symbolView.setContentHuggingPriority(.required, for: .horizontal)
		symbolView.setContentCompressionResistancePriority(.required, for: .horizontal)

		titleField.font = NSFont.preferredFont(forTextStyle: .body)
		titleField.lineBreakMode = .byTruncatingTail
		// The title takes the row's free width, so every accessory stands at the trailing edge.
		titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
		titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let subheadline = NSFont.preferredFont(forTextStyle: .subheadline)
		countField.font = NSFont.monospacedDigitSystemFont(ofSize: subheadline.pointSize, weight: .regular)
		countField.textColor = .secondaryLabelColor
		countField.alignment = .right
		countField.setContentHuggingPriority(.required, for: .horizontal)
		countField.setContentCompressionResistancePriority(.required, for: .horizontal)

		spinner.style = .spinning
		spinner.controlSize = .small
		spinner.isDisplayedWhenStopped = false
		spinner.setContentHuggingPriority(.required, for: .horizontal)

		accessorySymbolView.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
		accessorySymbolView.contentTintColor = InterfacePalette.attention
		accessorySymbolView.setContentHuggingPriority(.required, for: .horizontal)
		accessorySymbolView.setContentCompressionResistancePriority(.required, for: .horizontal)
	}

	private func configureLayout() {
		let stack = NSStackView(views: [symbolView, titleField, countField, spinner, accessorySymbolView])
		stack.orientation = .horizontal
		stack.alignment = .centerY
		stack.distribution = .fill
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)

		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			symbolView.widthAnchor.constraint(equalToConstant: 18),
		])
	}

	/// The website's section colours: blue for the archive, orange for what needs attention, and
	/// green for the folders on this Mac. Add Folder… is a command, so it stays grey.
	private static func symbolColor(of kind: SidebarItemKind) -> NSColor {
		switch kind {
		case .destination(.library):
			InterfacePalette.archive
		case .destination(.needsAttention):
			InterfacePalette.attention
		case .destination(.folder):
			InterfacePalette.collector
		case .addFolder:
			.secondaryLabelColor
		}
	}
}
