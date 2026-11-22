import AppKit

/// Painted stand-in for macOS unified toolbar glass, which renders black or transparent offscreen.
final class PaintedToolbarView: NSView {
	private let titleLabel = NSTextField(labelWithString: "")
	private let subtitleLabel = NSTextField(labelWithString: "")
	private let searchField = NSTextField(labelWithString: "")

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	convenience init(
		title: String,
		subtitle: String?,
		searchText: String,
		showsBackButton: Bool,
		width: CGFloat
	) {
		self.init(frame: NSRect(x: 0, y: 0, width: width, height: 46))
		configureViews(
			title: title,
			subtitle: subtitle,
			searchText: searchText,
			showsBackButton: showsBackButton
		)
	}

	override func draw(_ dirtyRect: NSRect) {
		let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		let background = isDark ? NSColor(calibratedWhite: 0.14, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)
		background.setFill()
		dirtyRect.fill()

		NSColor.separatorColor.setFill()
		NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

		let lights: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
		for (index, color) in lights.enumerated() {
			let circle = NSRect(x: 16 + CGFloat(index) * 20, y: 17, width: 12, height: 12)
			color.withAlphaComponent(0.9).setFill()
			NSBezierPath(ovalIn: circle).fill()
		}
	}

	private func configureViews(
		title: String,
		subtitle: String?,
		searchText: String,
		showsBackButton: Bool
	) {
		let sidebarSymbol = makeSymbolView("sidebar.leading")
		var leftItems: [NSView] = [sidebarSymbol]
		if showsBackButton {
			leftItems.append(makeSymbolView("chevron.left"))
		}

		titleLabel.stringValue = title
		titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		subtitleLabel.stringValue = subtitle ?? ""
		subtitleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		subtitleLabel.textColor = .secondaryLabelColor
		subtitleLabel.isHidden = subtitle == nil

		let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
		titleStack.orientation = .vertical
		titleStack.alignment = .leading
		titleStack.spacing = 0

		let searchPill = makeSearchPill(text: searchText)
		let sortSymbol = makeSymbolView("arrow.up.arrow.down")
		let shareSymbol = makeSymbolView("square.and.arrow.up")
		let inspectorSymbol = makeSymbolView("sidebar.trailing")

		let rightStack = NSStackView(views: [sortSymbol, searchPill, shareSymbol, inspectorSymbol])
		rightStack.orientation = .horizontal
		rightStack.alignment = .centerY
		rightStack.spacing = 12
		rightStack.translatesAutoresizingMaskIntoConstraints = false

		let leftStack = NSStackView(views: leftItems + [titleStack])
		leftStack.orientation = .horizontal
		leftStack.alignment = .centerY
		leftStack.spacing = 12
		leftStack.translatesAutoresizingMaskIntoConstraints = false

		addSubview(leftStack)
		addSubview(rightStack)

		NSLayoutConstraint.activate([
			heightAnchor.constraint(equalToConstant: 46),
			leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 92),
			leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),
			rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
			rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
			searchPill.widthAnchor.constraint(equalToConstant: 210),
			searchPill.heightAnchor.constraint(equalToConstant: 26),
		])
	}

	private func makeSymbolView(_ name: String) -> NSImageView {
		let imageView = NSImageView()
		imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
		imageView.contentTintColor = .secondaryLabelColor
		imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
		return imageView
	}

	private func makeSearchPill(text: String) -> NSView {
		// A box draws its colours in the appearance it draws in, where a layer keeps the one it was given.
		let box = NSBox()
		box.boxType = .custom
		box.titlePosition = .noTitle
		box.cornerRadius = 6
		box.borderWidth = 0.5
		box.borderColor = .separatorColor
		box.fillColor = .textBackgroundColor
		box.contentViewMargins = .zero

		let glyph = makeSymbolView("magnifyingglass")
		glyph.translatesAutoresizingMaskIntoConstraints = false
		glyph.setContentHuggingPriority(.required, for: .horizontal)
		searchField.stringValue = text.isEmpty ? "Search" : text
		searchField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		searchField.textColor = text.isEmpty ? .placeholderTextColor : .labelColor
		searchField.lineBreakMode = .byTruncatingTail
		searchField.translatesAutoresizingMaskIntoConstraints = false

		let content = box.contentView ?? box
		content.addSubview(glyph)
		content.addSubview(searchField)
		NSLayoutConstraint.activate([
			glyph.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
			glyph.centerYAnchor.constraint(equalTo: content.centerYAnchor),
			searchField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
			searchField.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -8),
			searchField.centerYAnchor.constraint(equalTo: content.centerYAnchor),
		])
		return box
	}
}
