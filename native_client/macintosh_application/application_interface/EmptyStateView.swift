import AppKit
import ApplicationPresentation

/// AppKit has no content-unavailable view, so this draws every empty state of the window: a picture
/// at 44 points, a title, a detail of at most 360 points, and at most one button.
final class EmptyStateView: NSView {
	private static let pictureSize: CGFloat = 44

	private let symbolView = NSImageView()
	private let drawerView = NSImageView()
	private let spinner = NSProgressIndicator()
	private let titleLabel = NSTextField(labelWithString: "")
	private let detailLabel = NSTextField(wrappingLabelWithString: "")
	private let actionButton = NSButton()
	private var onAction: ((EmptyStateAction) -> Void)?
	private var shownAction: EmptyStateAction?

	var actionControl: NSView {
		actionButton
	}

	init(onAction: @escaping (EmptyStateAction) -> Void) {
		self.onAction = onAction
		super.init(frame: .zero)
		configureControls()
		configureLayout()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	/// `defaultAction` makes the button the window's default, which only a page that stands alone
	/// should claim.
	func render(_ presentation: EmptyStatePresentation, defaultAction: Bool = false) {
		symbolView.isHidden = true
		drawerView.isHidden = true
		spinner.isHidden = true
		spinner.stopAnimation(nil)
		switch presentation.picture {
		case let .symbol(name):
			symbolView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
			symbolView.isHidden = false
		case .emptyDrawer:
			drawerView.isHidden = false
		case .progress:
			spinner.isHidden = false
			spinner.startAnimation(nil)
		}
		titleLabel.stringValue = presentation.title
		detailLabel.stringValue = presentation.detail
		detailLabel.isHidden = presentation.detail.isEmpty
		shownAction = presentation.action
		actionButton.isHidden = presentation.action == nil
		actionButton.title = presentation.action?.title ?? ""
		actionButton.keyEquivalent = defaultAction ? "\r" : ""
	}

	private func configureControls() {
		symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.pictureSize, weight: .light)
		symbolView.contentTintColor = .tertiaryLabelColor
		symbolView.setAccessibilityElement(false)

		drawerView.image = DrawerGlyph.emptyDrawer(width: Self.pictureSize + 8)
		drawerView.contentTintColor = .tertiaryLabelColor
		drawerView.setAccessibilityElement(false)

		spinner.style = .spinning
		spinner.controlSize = .regular
		spinner.isDisplayedWhenStopped = false

		titleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize)
		titleLabel.alignment = .center
		titleLabel.setAccessibilityIdentifier(InterfaceIdentifier.emptyStateTitle)

		detailLabel.font = NSFont.preferredFont(forTextStyle: .body)
		detailLabel.textColor = .secondaryLabelColor
		detailLabel.alignment = .center
		detailLabel.setAccessibilityIdentifier(InterfaceIdentifier.emptyStateDetail)

		actionButton.bezelStyle = .push
		actionButton.controlSize = .large
		actionButton.target = self
		actionButton.action = #selector(actionPressed)
		actionButton.isHidden = true
		actionButton.setAccessibilityIdentifier(InterfaceIdentifier.emptyStateAction)
	}

	private func configureLayout() {
		let picture = NSView()
		for view in [symbolView, drawerView, spinner] {
			view.translatesAutoresizingMaskIntoConstraints = false
			picture.addSubview(view)
			NSLayoutConstraint.activate([
				view.centerXAnchor.constraint(equalTo: picture.centerXAnchor),
				view.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
			])
		}
		NSLayoutConstraint.activate([
			picture.widthAnchor.constraint(equalToConstant: Self.pictureSize + 8),
			picture.heightAnchor.constraint(equalToConstant: Self.pictureSize + 8),
		])

		let stack = NSStackView(views: [picture, titleLabel, detailLabel, actionButton])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 6
		stack.setCustomSpacing(12, after: picture)
		stack.setCustomSpacing(18, after: detailLabel)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)

		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
			detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
		])
	}

	@objc private func actionPressed() {
		shownAction.map { onAction?($0) }
	}
}
