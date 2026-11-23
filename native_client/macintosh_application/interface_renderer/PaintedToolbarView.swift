import AppKit
import ApplicationInterface

/// Painted stand-in for macOS unified toolbar glass, which renders black or transparent offscreen.
/// It sets the items where the window's toolbar sets them, over the parts of the workspace's split
/// view: the sidebar's toggle and Back over the sidebar, the title and Sort over the list, Share
/// and the search field over the reader, and the inspector's toggle at the trailing edge. A page
/// that collapsed the list and the inspector shows only the search field after the title.
final class PaintedToolbarView: NSView {
	/// Where the parts of the split view end, read from it once the scene has laid out.
	private struct Sections {
		var sidebarEnd: CGFloat
		var listEnd: CGFloat?
		var readerEnd: CGFloat
	}

	private static let height: CGFloat = 46
	private static let searchWidth: CGFloat = 240

	private let titleStack = NSStackView()
	private let sidebarSymbol = PaintedToolbarView.makeSymbolView("sidebar.leading")
	private let backSymbol = PaintedToolbarView.makeSymbolView("chevron.backward")
	private let sortSymbol = PaintedToolbarView.makeSymbolView("arrow.up.arrow.down")
	private let shareSymbol = PaintedToolbarView.makeSymbolView("square.and.arrow.up")
	private let inspectorSymbol = PaintedToolbarView.makeSymbolView("sidebar.trailing")
	private let searchPill: NSView
	private var sections: Sections?

	init(title: String, subtitle: String?, searchText: String, showsBackButton: Bool, width: CGFloat) {
		searchPill = Self.makeSearchPill(text: searchText)
		super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
		wantsLayer = true
		backSymbol.isHidden = !showsBackButton

		let titleLabel = NSTextField(labelWithString: title)
		titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		titleLabel.lineBreakMode = .byTruncatingTail
		let subtitleLabel = NSTextField(labelWithString: subtitle ?? "")
		subtitleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		subtitleLabel.textColor = .secondaryLabelColor
		subtitleLabel.isHidden = subtitle == nil
		titleStack.setViews([titleLabel, subtitleLabel], in: .leading)
		titleStack.orientation = .vertical
		titleStack.alignment = .leading
		titleStack.spacing = 0

		for view in [sidebarSymbol, backSymbol, titleStack, sortSymbol, shareSymbol, searchPill, inspectorSymbol] {
			view.translatesAutoresizingMaskIntoConstraints = true
			addSubview(view)
		}
		heightAnchor.constraint(equalToConstant: Self.height).isActive = true
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	/// Reads the parts' edges from the workspace's split view, whose four items are the sidebar,
	/// the list, the reader, and the inspector.
	func align(to workspace: LibraryWorkspaceViewController) {
		let items = workspace.splitViewItems
		guard items.count == 4 else {
			return
		}
		let edges = items.map { item in
			item.viewController.view.convert(item.viewController.view.bounds, to: self).maxX
		}
		sections = Sections(
			sidebarEnd: edges[0],
			listEnd: items[1].isCollapsed ? nil : edges[1],
			readerEnd: items[3].isCollapsed ? bounds.width : edges[2]
		)
		needsLayout = true
		layoutSubtreeIfNeeded()
	}

	override func layout() {
		super.layout()
		guard let sections else {
			return
		}
		let showsDocuments = sections.listEnd != nil
		var leading: CGFloat = 92
		place(sidebarSymbol, leading: leading)
		leading = sidebarSymbol.frame.maxX + 16
		if !backSymbol.isHidden {
			place(backSymbol, leading: leading)
		}

		var trailing = bounds.width - 16
		inspectorSymbol.isHidden = !showsDocuments
		if showsDocuments {
			place(inspectorSymbol, trailing: trailing)
			trailing = inspectorSymbol.frame.minX - 16
		}
		let searchTrailing = min(trailing, sections.readerEnd - 12)
		searchPill.frame = NSRect(
			x: searchTrailing - Self.searchWidth,
			y: (bounds.height - 26) / 2,
			width: Self.searchWidth,
			height: 26
		)
		shareSymbol.isHidden = !showsDocuments
		sortSymbol.isHidden = !showsDocuments
		if showsDocuments {
			place(shareSymbol, trailing: searchPill.frame.minX - 14)
		}

		let titleLeading = sections.sidebarEnd + 14
		var titleEnd = searchPill.frame.minX - 14
		if let listEnd = sections.listEnd {
			place(sortSymbol, trailing: listEnd - 14)
			titleEnd = sortSymbol.frame.minX - 8
		}
		let titleHeight = titleStack.fittingSize.height
		titleStack.frame = NSRect(
			x: titleLeading,
			y: (bounds.height - titleHeight) / 2,
			width: max(0, min(titleStack.fittingSize.width, titleEnd - titleLeading)),
			height: titleHeight
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

	private func place(_ view: NSView, leading: CGFloat) {
		let size = view.fittingSize
		view.frame = NSRect(x: leading, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
	}

	private func place(_ view: NSView, trailing: CGFloat) {
		place(view, leading: trailing - view.fittingSize.width)
	}

	private static func makeSymbolView(_ name: String) -> NSImageView {
		let imageView = NSImageView()
		imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
		imageView.contentTintColor = .secondaryLabelColor
		imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
		return imageView
	}

	private static func makeSearchPill(text: String) -> NSView {
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
		let searchField = NSTextField(labelWithString: text.isEmpty ? "Search" : text)
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
