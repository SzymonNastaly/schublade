import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// A document's row: the first page's picture, a title of up to two lines, the sender and the date
/// with the amount at the trailing edge, and a third line only when it adds something. A document
/// in ingestion shows a spinner beside its title, and a failed one an orange mark.
final class DocumentRowView: NSTableCellView {
	private static let pictureSize = NSSize(width: 40, height: 52)
	private static let verticalMargin: CGFloat = 8
	private static let lineSpacing: CGFloat = 2
	private static let statusSpacing: CGFloat = 6
	private static let statusSize: CGFloat = 16
	private static let horizontalMargin: CGFloat = 12
	private static let pictureGap: CGFloat = 10
	/// The width beside the text: both margins, the picture, and its gap.
	private static let textInsets = 2 * horizontalMargin + pictureSize.width + pictureGap
	private static let titleFont = NSFont.preferredFont(forTextStyle: .headline)
	private static let detailFont = NSFont.preferredFont(forTextStyle: .subheadline)

	/// The one height of every row, from the fonts' line heights, so the table places any number of
	/// rows without measuring one: two lines of title or one with a third line, under the sender's.
	static let rowHeight: CGFloat = {
		let layout = NSLayoutManager()
		let title = layout.defaultLineHeight(for: titleFont)
		let detail = layout.defaultLineHeight(for: detailFont)
		let text = max(2 * title, title + lineSpacing + detail) + lineSpacing + detail
		return ceil(max(pictureSize.height, text) + 2 * verticalMargin)
	}()

	private let pictureFrame = NSView()
	private let fallbackGlyphView = NSImageView()
	private let pictureView = NSImageView()
	private let titleField = NSTextField(wrappingLabelWithString: "")
	private let progressIndicator = NSProgressIndicator()
	private let failureMark = NSImageView()
	/// Holds the spinner or the failure mark at the trailing edge, centred on the title's first line.
	private let statusFrame = NSView()
	private let senderLine = NSStackView()
	private let senderField = NSTextField(labelWithString: "")
	private let dateField = NSTextField(labelWithString: "")
	private let amountField = NSTextField(labelWithString: "")
	private let detailField = NSTextField(labelWithString: "")

	private var representedDocument: DocumentIdentifier?
	private var thumbnailTask: Task<Void, Never>?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		configurePicture()
		configureFields()
		configureLayout()
		setAccessibilityElement(true)
		setAccessibilityRole(.cell)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	/// The frame of the first page's picture, which Quick Look grows out of and returns to.
	var pictureFrameInWindow: NSRect {
		pictureFrame.convert(pictureFrame.bounds, to: nil)
	}

	/// The picture as the row shows it, or nil while it shows the fallback symbol.
	var shownPicture: NSImage? {
		pictureView.isHidden ? nil : pictureView.image
	}

	/// A layer keeps the colour it was given, so the picture's frame follows the appearance here.
	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		applyPictureFrameColors()
	}

	/// A title wraps at the width the row gives it, which follows from the row's width alone, so
	/// the wrap never waits for a layout that the wrap itself would change.
	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		updateTitleWrapWidth()
	}

	override func prepareForReuse() {
		super.prepareForReuse()
		thumbnailTask?.cancel()
		thumbnailTask = nil
		representedDocument = nil
		showPicture(nil)
	}

	func configure(
		with row: DocumentRow,
		placement: DocumentRowPlacement,
		context: WordingContext,
		pictureStore: PictureStore?
	) {
		thumbnailTask?.cancel()
		thumbnailTask = nil
		representedDocument = row.document

		let presentation = DocumentRowPresentation.from(row, placement: placement, context: context)
		titleField.stringValue = presentation.title
		titleField.maximumNumberOfLines = presentation.showsThirdLine ? 1 : 2
		senderField.stringValue = presentation.sender
		senderField.isHidden = presentation.sender.isEmpty
		let date = presentation.dateText ?? ""
		dateField.stringValue = presentation.sender.isEmpty || date.isEmpty ? date : "· \(date)"
		amountField.stringValue = presentation.amountText ?? ""
		amountField.isHidden = presentation.amountText == nil
		senderLine.isHidden = presentation.sender.isEmpty && date.isEmpty && presentation.amountText == nil
		if case let .searching(searchText) = placement, case .excerpt = row.passage, case .archived = row.condition {
			detailField.attributedStringValue = Self.markedExcerpt(presentation.thirdLineText, searchText: searchText)
		} else {
			detailField.font = Self.detailFont
			detailField.stringValue = presentation.thirdLineText
			detailField.textColor = color(for: presentation.thirdLineTone)
		}
		detailField.isHidden = !presentation.showsThirdLine
		showCondition(row.condition)
		updateTitleWrapWidth()

		let spoken = [presentation.title, presentation.sender, presentation.dateText, presentation.amountText]
			.compactMap(\.self)
			.filter { !$0.isEmpty }
		setAccessibilityLabel(spoken.joined(separator: ", "))
		setAccessibilityValue(presentation.showsThirdLine ? presentation.thirdLineText : nil)

		applyPicture(for: row.document, contentKnown: presentation.contentKnown, pictureStore: pictureStore)
	}

	private func showCondition(_ condition: DocumentCondition) {
		switch condition {
		case .inIngestion:
			statusFrame.isHidden = false
			progressIndicator.isHidden = false
			progressIndicator.startAnimation(nil)
			failureMark.isHidden = true
		case .failed:
			statusFrame.isHidden = false
			progressIndicator.stopAnimation(nil)
			progressIndicator.isHidden = true
			failureMark.isHidden = false
		case .archived:
			statusFrame.isHidden = true
			progressIndicator.stopAnimation(nil)
			progressIndicator.isHidden = true
			failureMark.isHidden = true
		}
	}

	private func updateTitleWrapWidth() {
		let statusWidth = statusFrame.isHidden ? 0 : Self.statusSize + Self.statusSpacing
		let width = max(0, bounds.width - Self.textInsets - statusWidth)
		if titleField.preferredMaxLayoutWidth != width {
			titleField.preferredMaxLayoutWidth = width
		}
	}

	private func applyPicture(
		for document: DocumentIdentifier,
		contentKnown: Bool,
		pictureStore: PictureStore?
	) {
		guard contentKnown, let pictureStore else {
			showPicture(nil)
			return
		}
		if let cached = pictureStore.cachedPicture(for: document) {
			showPicture(cached)
			return
		}
		showPicture(nil)
		thumbnailTask = Task { [weak self] in
			let image = await pictureStore.picture(for: document)
			guard let self, !Task.isCancelled, representedDocument == document else {
				return
			}
			showPicture(image)
		}
	}

	private func showPicture(_ image: NSImage?) {
		pictureView.image = image.map(Self.topOfPage)
		pictureView.isHidden = image == nil
		fallbackGlyphView.isHidden = image != nil
		applyPictureFrameColors()
	}

	/// The page scaled to fill the frame and cut from its top edge, where a letter names itself.
	private static func topOfPage(_ page: NSImage) -> NSImage {
		NSImage(size: pictureSize, flipped: false) { rect in
			guard page.size.width > 0, page.size.height > 0 else {
				return false
			}
			let scale = max(rect.width / page.size.width, rect.height / page.size.height)
			let size = NSSize(width: page.size.width * scale, height: page.size.height * scale)
			let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY - size.height)
			page.draw(in: NSRect(origin: origin, size: size))
			return true
		}
	}

	private func applyPictureFrameColors() {
		effectiveAppearance.performAsCurrentDrawingAppearance {
			pictureFrame.layer?.borderColor = NSColor.separatorColor.cgColor
			let fill: NSColor = pictureView.isHidden ? .quaternarySystemFill : .textBackgroundColor
			pictureFrame.layer?.backgroundColor = fill.cgColor
		}
	}

	/// A passage of the text in the third line's colour, with each word that matched in the label's
	/// colour at semibold.
	private static func markedExcerpt(_ excerpt: String, searchText: String) -> NSAttributedString {
		let paragraph = NSMutableParagraphStyle()
		paragraph.lineBreakMode = .byTruncatingTail
		let marked = NSMutableAttributedString(string: excerpt, attributes: [
			.font: detailFont,
			.foregroundColor: NSColor.secondaryLabelColor,
			.paragraphStyle: paragraph,
		])
		let semibold = NSFont.systemFont(ofSize: detailFont.pointSize, weight: .semibold)
		for range in SearchTextMarking.matchedRanges(in: excerpt, searchText: searchText) {
			marked.addAttributes(
				[.font: semibold, .foregroundColor: NSColor.labelColor],
				range: NSRange(range, in: excerpt)
			)
		}
		return marked
	}

	private func color(for tone: DocumentRowThirdLineTone) -> NSColor {
		switch tone {
		case .secondary:
			.secondaryLabelColor
		case .accent:
			InterfacePalette.archive
		case .failure:
			InterfacePalette.attention
		}
	}
}

private extension DocumentRowView {
	func configurePicture() {
		pictureFrame.wantsLayer = true
		pictureFrame.layer?.cornerRadius = 4
		pictureFrame.layer?.borderWidth = 0.5
		pictureFrame.layer?.masksToBounds = true
		pictureFrame.translatesAutoresizingMaskIntoConstraints = false
		pictureFrame.setAccessibilityIdentifier(InterfaceIdentifier.documentRowThumbnail)

		fallbackGlyphView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
		fallbackGlyphView.contentTintColor = .tertiaryLabelColor
		fallbackGlyphView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
		fallbackGlyphView.translatesAutoresizingMaskIntoConstraints = false

		pictureView.imageScaling = .scaleNone
		pictureView.isHidden = true
		pictureView.translatesAutoresizingMaskIntoConstraints = false

		pictureFrame.addSubview(fallbackGlyphView)
		pictureFrame.addSubview(pictureView)
	}

	func configureFields() {
		titleField.font = Self.titleFont
		titleField.textColor = .labelColor
		titleField.maximumNumberOfLines = 2
		titleField.lineBreakMode = .byWordWrapping
		titleField.cell?.truncatesLastVisibleLine = true
		titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
		titleField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowTitle)

		progressIndicator.style = .spinning
		progressIndicator.controlSize = .small
		progressIndicator.isDisplayedWhenStopped = false
		progressIndicator.isHidden = true

		failureMark.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Failed")
		failureMark.contentTintColor = InterfacePalette.attention
		failureMark.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .subheadline)
		failureMark.isHidden = true

		for status in [progressIndicator, failureMark] as [NSView] {
			status.translatesAutoresizingMaskIntoConstraints = false
			statusFrame.addSubview(status)
			NSLayoutConstraint.activate([
				status.centerXAnchor.constraint(equalTo: statusFrame.centerXAnchor),
				status.centerYAnchor.constraint(equalTo: statusFrame.centerYAnchor),
			])
		}
		statusFrame.isHidden = true

		senderField.font = Self.detailFont
		senderField.textColor = .secondaryLabelColor
		senderField.lineBreakMode = .byTruncatingTail
		senderField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		senderField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowSender)

		dateField.font = Self.detailFont
		dateField.textColor = .secondaryLabelColor
		dateField.setContentHuggingPriority(.required, for: .horizontal)
		dateField.setContentCompressionResistancePriority(.required, for: .horizontal)
		dateField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowDate)

		amountField.font = NSFont.monospacedDigitSystemFont(ofSize: Self.detailFont.pointSize, weight: .medium)
		amountField.textColor = .labelColor
		amountField.alignment = .right
		amountField.setContentHuggingPriority(.required, for: .horizontal)
		amountField.setContentCompressionResistancePriority(.required, for: .horizontal)
		amountField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowAmount)

		detailField.font = Self.detailFont
		detailField.textColor = .secondaryLabelColor
		detailField.lineBreakMode = .byTruncatingTail
		detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		detailField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowDetail)

		// The row speaks as one element, so its parts do not speak again.
		for part in [titleField, senderField, dateField, amountField, detailField, pictureFrame] as [NSView] {
			part.setAccessibilityElement(false)
		}
	}

	func configureLayout() {
		let titleLine = NSStackView(views: [titleField, statusFrame])
		titleLine.orientation = .horizontal
		titleLine.alignment = .top
		titleLine.spacing = Self.statusSpacing
		titleLine.distribution = .fill

		let flexibleSpace = NSView()
		flexibleSpace.setContentHuggingPriority(.init(1), for: .horizontal)
		for part in [senderField, dateField, flexibleSpace, amountField] {
			senderLine.addArrangedSubview(part)
		}
		senderLine.orientation = .horizontal
		senderLine.alignment = .firstBaseline
		senderLine.spacing = 4
		senderLine.setCustomSpacing(12, after: flexibleSpace)

		let textColumn = NSStackView(views: [titleLine, senderLine, detailField])
		textColumn.orientation = .vertical
		textColumn.alignment = .leading
		textColumn.spacing = Self.lineSpacing
		textColumn.detachesHiddenViews = true
		textColumn.translatesAutoresizingMaskIntoConstraints = false

		addSubview(pictureFrame)
		addSubview(textColumn)

		NSLayoutConstraint.activate([
			pictureFrame.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalMargin),
			pictureFrame.centerYAnchor.constraint(equalTo: centerYAnchor),
			pictureFrame.widthAnchor.constraint(equalToConstant: Self.pictureSize.width),
			pictureFrame.heightAnchor.constraint(equalToConstant: Self.pictureSize.height),
			fallbackGlyphView.centerXAnchor.constraint(equalTo: pictureFrame.centerXAnchor),
			fallbackGlyphView.centerYAnchor.constraint(equalTo: pictureFrame.centerYAnchor),
			pictureView.leadingAnchor.constraint(equalTo: pictureFrame.leadingAnchor),
			pictureView.trailingAnchor.constraint(equalTo: pictureFrame.trailingAnchor),
			pictureView.topAnchor.constraint(equalTo: pictureFrame.topAnchor),
			pictureView.bottomAnchor.constraint(equalTo: pictureFrame.bottomAnchor),
			textColumn.leadingAnchor.constraint(equalTo: pictureFrame.trailingAnchor, constant: Self.pictureGap),
			textColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalMargin),
			textColumn.topAnchor.constraint(equalTo: pictureFrame.topAnchor, constant: -1),
			titleLine.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
			statusFrame.widthAnchor.constraint(equalToConstant: Self.statusSize),
			statusFrame.heightAnchor.constraint(
				equalToConstant: ceil(NSLayoutManager().defaultLineHeight(for: Self.titleFont))
			),
			senderLine.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
			detailField.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
		])
	}
}
