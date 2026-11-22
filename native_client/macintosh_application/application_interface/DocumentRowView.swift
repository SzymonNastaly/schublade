import AppKit
import ApplicationBindings
import ApplicationPresentation

/// Three-line document row cell with async-decoded 40x52 first-page thumbnail.
final class DocumentRowView: NSTableCellView {
	private let thumbnailContainer = NSView()
	private let fallbackGlyphView = NSImageView()
	private let thumbnailImageView = NSImageView()
	private let titleField = NSTextField(labelWithString: "")
	private let dateField = NSTextField(labelWithString: "")
	private let senderField = NSTextField(labelWithString: "")
	private let amountField = NSTextField(labelWithString: "")
	private let detailField = NSTextField(labelWithString: "")

	private var representedDocument: DocumentIdentifier?
	private var thumbnailTask: Task<Void, Never>?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		configureThumbnail()
		configureFields()
		configureLayout()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func prepareForReuse() {
		super.prepareForReuse()
		thumbnailTask?.cancel()
		thumbnailTask = nil
		representedDocument = nil
		thumbnailImageView.image = nil
		thumbnailImageView.isHidden = true
		fallbackGlyphView.isHidden = false
	}

	func configure(
		with row: DocumentRow,
		context: WordingContext,
		pictureStore: PictureStore?
	) {
		thumbnailTask?.cancel()
		thumbnailTask = nil
		representedDocument = row.document

		let presentation = DocumentRowPresentation.from(row, context: context)
		titleField.stringValue = presentation.title
		dateField.stringValue = presentation.dateText ?? ""
		senderField.stringValue = presentation.sender
		amountField.stringValue = presentation.amountText ?? ""
		amountField.isHidden = presentation.amountText == nil
		detailField.stringValue = presentation.thirdLineText
		detailField.textColor = color(for: presentation.thirdLineTone)

		applyThumbnail(for: row.document, contentKnown: presentation.contentKnown, pictureStore: pictureStore)
	}

	private func applyThumbnail(
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
		if let image {
			thumbnailImageView.image = image
			thumbnailImageView.isHidden = false
			fallbackGlyphView.isHidden = true
		} else {
			thumbnailImageView.image = nil
			thumbnailImageView.isHidden = true
			fallbackGlyphView.isHidden = false
		}
	}

	private func configureThumbnail() {
		thumbnailContainer.wantsLayer = true
		thumbnailContainer.layer?.cornerRadius = 4
		thumbnailContainer.layer?.borderWidth = 0.5
		thumbnailContainer.layer?.borderColor = NSColor.separatorColor.cgColor
		thumbnailContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
		thumbnailContainer.layer?.masksToBounds = true
		thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
		thumbnailContainer.setAccessibilityIdentifier(InterfaceIdentifier.documentRowThumbnail)

		fallbackGlyphView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
		fallbackGlyphView.contentTintColor = .tertiaryLabelColor
		fallbackGlyphView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
		fallbackGlyphView.translatesAutoresizingMaskIntoConstraints = false

		thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
		thumbnailImageView.isHidden = true
		thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false

		thumbnailContainer.addSubview(fallbackGlyphView)
		thumbnailContainer.addSubview(thumbnailImageView)
	}

	private func configureFields() {
		titleField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		titleField.lineBreakMode = .byTruncatingTail
		titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		titleField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowTitle)

		dateField.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
		dateField.textColor = .secondaryLabelColor
		dateField.setContentHuggingPriority(.required, for: .horizontal)
		dateField.setContentCompressionResistancePriority(.required, for: .horizontal)
		dateField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowDate)

		senderField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		senderField.textColor = .secondaryLabelColor
		senderField.lineBreakMode = .byTruncatingTail
		senderField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		senderField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowSender)

		amountField.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
		amountField.textColor = .labelColor
		amountField.setContentHuggingPriority(.required, for: .horizontal)
		amountField.setContentCompressionResistancePriority(.required, for: .horizontal)
		amountField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowAmount)

		detailField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		detailField.textColor = .secondaryLabelColor
		detailField.lineBreakMode = .byTruncatingTail
		detailField.setAccessibilityIdentifier(InterfaceIdentifier.documentRowDetail)
	}

	private func configureLayout() {
		let topRow = NSStackView(views: [titleField, dateField])
		topRow.orientation = .horizontal
		topRow.alignment = .firstBaseline
		topRow.spacing = 8

		let middleRow = NSStackView(views: [senderField, amountField])
		middleRow.orientation = .horizontal
		middleRow.alignment = .firstBaseline
		middleRow.spacing = 8

		let textColumn = NSStackView(views: [topRow, middleRow, detailField])
		textColumn.orientation = .vertical
		textColumn.alignment = .leading
		textColumn.spacing = 2
		textColumn.translatesAutoresizingMaskIntoConstraints = false

		addSubview(thumbnailContainer)
		addSubview(textColumn)

		NSLayoutConstraint.activate([
			thumbnailContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			thumbnailContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
			thumbnailContainer.widthAnchor.constraint(equalToConstant: 40),
			thumbnailContainer.heightAnchor.constraint(equalToConstant: 52),
			fallbackGlyphView.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
			fallbackGlyphView.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),
			thumbnailImageView.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
			thumbnailImageView.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
			thumbnailImageView.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor),
			thumbnailImageView.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),
			textColumn.leadingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: 10),
			textColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
			textColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
			topRow.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
			middleRow.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
			detailField.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
		])
	}

	private func color(for tone: DocumentRowThirdLineTone) -> NSColor {
		switch tone {
		case .secondary:
			.secondaryLabelColor
		case .accent:
			.controlAccentColor
		case .failure:
			.systemRed
		}
	}
}
