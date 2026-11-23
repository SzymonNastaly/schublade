import ApplicationBindings
import LibraryPresentation
import UIKit

/// One row of the library: a document, or an arrival on its way to becoming one. Both draw from
/// this value, so the picture and the text stay in place when an arrival becomes its document.
struct DocumentRowContent: UIContentConfiguration, Equatable {
	/// Which row this is, such as "document.<identifier>". A change animates only within one row,
	/// because a reused cell may show another.
	let identity: String
	/// The listed document the row shows, whose picture it reads; nil for an arrival.
	var document: DocumentIdentifier?
	let row: DocumentRowPresentation
	let picture: UIImage?
	let trailing: RowTrailingIndicator
	/// What VoiceOver reads after the row's label, nil for the third line.
	let spokenValue: String?
	/// An arrival changes as it is sent and read.
	let updatesFrequently: Bool
	/// The search whose words the third line marks, nil for a line without an excerpt.
	var markedSearch: String?

	func makeContentView() -> any UIView & UIContentView {
		DocumentRowContentView(configuration: self)
	}

	func updated(for _: any UIConfigurationState) -> DocumentRowContent {
		self
	}

	/// Makes the cell one element for VoiceOver: the title, the sender, the date, and the amount,
	/// then the stage or the third line. A picture is not an element.
	func describe(_ cell: UICollectionViewListCell) {
		cell.isAccessibilityElement = true
		cell.accessibilityLabel = [row.title, row.sender, row.dateText, row.amountText]
			.compactMap { $0?.isEmpty == false ? $0 : nil }
			.joined(separator: ", ")
		cell.accessibilityValue = spokenValue ?? (row.thirdLineText.isEmpty ? nil : row.thirdLineText)
		cell.accessibilityTraits = updatesFrequently ? [.button, .updatesFrequently] : [.button]
	}

	/// Where the text begins, for the separator below the row.
	static var textLeading: CGFloat {
		16 + RowPicture.size.width + 12
	}
}

/// The first page of a row, as `PagePicture` cuts and draws it.
enum RowPicture {
	nonisolated static let defaultSize = CGSize(width: 44, height: 58)

	/// The default size at the default text size, growing with the text up to 66 points wide.
	static var size: CGSize {
		let width = min(UIFontMetrics(forTextStyle: .body).scaledValue(for: defaultSize.width), 66)
		return CGSize(width: width.rounded(), height: (width * defaultSize.height / defaultSize.width).rounded())
	}

	/// The picture at its own pixels, three to a point, in the row's proportion.
	nonisolated static func framed(_ picture: CGImage) -> UIImage {
		let cut = PagePicture.cut(picture, proportion: defaultSize.width / defaultSize.height)
		return PagePicture.onPaper(
			cut,
			size: CGSize(width: Double(cut.width) / 3, height: Double(cut.height) / 3),
			scale: 3
		)
	}
}

final class DocumentRowContentView: UIView, UIContentView {
	private let pictureView = UIImageView()
	private let titleLabel = UILabel()
	private let senderLabel = SenderAndDateLabel()
	private let amountLabel = UILabel()
	private let thirdLabel = UILabel()
	private let caption = UIStackView()
	private let textStack = UIStackView()
	private let accessory = UIView()
	private let activityView = UIActivityIndicatorView(style: .medium)
	private let progressView = CircularProgressView()
	private let symbolView = UIImageView()
	private var pictureWidth: NSLayoutConstraint?
	private var pictureHeight: NSLayoutConstraint?
	private var accessorySize: NSLayoutConstraint?
	private var accessoryHeight: NSLayoutConstraint?
	private var textBeforeAccessory: NSLayoutConstraint?
	private var shown: DocumentRowContent

	var configuration: any UIContentConfiguration {
		get { shown }
		set {
			guard let next = newValue as? DocumentRowContent, next != shown else {
				return
			}
			let previous = shown
			shown = next
			apply(next, after: previous.identity == next.identity ? previous : nil)
		}
	}

	init(configuration: DocumentRowContent) {
		shown = configuration
		super.init(frame: .zero)
		buildText()
		buildAccessory()
		buildLayout()
		apply(configuration, after: nil)
		registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
			view.sizePicture()
			view.arrangeCaption()
			view.applyText(view.shown)
		}
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	private func buildText() {
		pictureView.layer.cornerRadius = 6
		pictureView.layer.cornerCurve = .continuous
		pictureView.clipsToBounds = true
		pictureView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
		pictureView.tintColor = .tertiaryLabel
		style(titleLabel, .headline, color: .label, lines: 2)
		style(senderLabel, .subheadline, color: .secondaryLabel, lines: 1)
		style(amountLabel, .subheadline, color: .label, lines: 1)
		amountLabel.font = RowCaptionText.amountFont
		style(thirdLabel, .footnote, color: .secondaryLabel, lines: 2)
		// The sender and the date take what the amount leaves, and the amount stays whole.
		senderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
		senderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		amountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		amountLabel.setContentHuggingPriority(.required, for: .horizontal)
		caption.addArrangedSubview(senderLabel)
		caption.addArrangedSubview(amountLabel)
		textStack.addArrangedSubview(titleLabel)
		textStack.addArrangedSubview(caption)
		textStack.addArrangedSubview(thirdLabel)
		textStack.axis = .vertical
		textStack.spacing = 3
		arrangeCaption()
	}

	private var accessibilitySized: Bool {
		traitCollection.preferredContentSizeCategory.isAccessibilityCategory
	}

	/// At an accessibility size the amount leaves the sender's line for a line of its own, which the
	/// date joins, and the title and the sender take more lines.
	private func arrangeCaption() {
		let large = accessibilitySized
		caption.axis = large ? .vertical : .horizontal
		caption.alignment = large ? .leading : .firstBaseline
		caption.spacing = large ? 3 : 8
		titleLabel.numberOfLines = large ? 4 : 2
		senderLabel.numberOfLines = large ? 2 : 1
		amountLabel.numberOfLines = large ? 2 : 1
	}

	private func buildAccessory() {
		activityView.hidesWhenStopped = true
		symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
		symbolView.contentMode = .center
		for part in [activityView, progressView, symbolView] as [UIView] {
			part.translatesAutoresizingMaskIntoConstraints = false
			accessory.addSubview(part)
			NSLayoutConstraint.activate([
				part.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
				part.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
				part.topAnchor.constraint(equalTo: accessory.topAnchor),
				part.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
			])
		}
	}

	private func buildLayout() {
		for subview in [pictureView, textStack, accessory] as [UIView] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			addSubview(subview)
		}
		directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
		// The row is as tall as the taller of the picture and the text, which both stay above its bottom.
		let shortest = heightAnchor.constraint(equalToConstant: 0)
		shortest.priority = .defaultLow
		let pictureWidth = pictureView.widthAnchor.constraint(equalToConstant: RowPicture.size.width)
		let pictureHeight = pictureView.heightAnchor.constraint(equalToConstant: RowPicture.size.height)
		let accessorySize = accessory.widthAnchor.constraint(equalToConstant: Self.accessorySide)
		let accessoryHeight = accessory.heightAnchor.constraint(equalToConstant: Self.accessorySide)
		// Without an accessory, its width and the space before it are zero, so one constraint holds the
		// text's trailing edge in every state.
		let textBeforeAccessory = textStack.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -12)
		NSLayoutConstraint.activate([
			pictureView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
			pictureView.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
			pictureWidth,
			pictureHeight,
			pictureView.bottomAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.bottomAnchor),
			textStack.leadingAnchor.constraint(equalTo: pictureView.trailingAnchor, constant: 12),
			textStack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
			textStack.bottomAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.bottomAnchor),
			accessory.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
			accessory.centerYAnchor.constraint(equalTo: pictureView.centerYAnchor),
			accessorySize,
			accessoryHeight,
			textBeforeAccessory,
			shortest,
		])
		self.pictureWidth = pictureWidth
		self.pictureHeight = pictureHeight
		self.accessorySize = accessorySize
		self.accessoryHeight = accessoryHeight
		self.textBeforeAccessory = textBeforeAccessory
	}

	private static var accessorySide: CGFloat {
		UIFontMetrics(forTextStyle: .title3).scaledValue(for: 22).rounded()
	}

	private func sizePicture() {
		pictureWidth?.constant = RowPicture.size.width
		pictureHeight?.constant = RowPicture.size.height
		accessorySize?.constant = shown.trailing == .absent ? 0 : Self.accessorySide
		accessoryHeight?.constant = Self.accessorySide
	}

	private func style(_ label: UILabel, _ style: UIFont.TextStyle, color: UIColor, lines: Int) {
		label.font = .preferredFont(forTextStyle: style)
		label.adjustsFontForContentSizeCategory = true
		label.textColor = color
		label.numberOfLines = lines
	}

	/// `previous` is this row's configuration before, nil for a row this view did not show.
	private func apply(_ content: DocumentRowContent, after previous: DocumentRowContent?) {
		let animated = previous != nil && window != nil
		let filedNow = previous?.trailing == .done(filed: false) && content.trailing == .done(filed: true)
		// The row cross-dissolves by fading a picture of its former self, because a stack view whose
		// labels are shown or hidden inside an animation can keep its former arrangement.
		if filedNow, animated, let former = snapshotView(afterScreenUpdates: false) {
			former.frame = bounds
			addSubview(former)
			applyText(content)
			UIView.animate(withDuration: 0.25) {
				former.alpha = 0
			} completion: { _ in
				former.removeFromSuperview()
			}
		} else {
			applyText(content)
		}
		applyTrailing(content.trailing, after: previous?.trailing, animated: animated)
		if filedNow, animated, !UIAccessibility.isReduceMotionEnabled {
			symbolView.addSymbolEffect(.bounce, options: .nonRepeating)
		}
	}

	private func applyText(_ content: DocumentRowContent) {
		let row = content.row
		pictureView.showPage(content.picture, placeholder: "doc.text")
		titleLabel.text = row.title
		let large = accessibilitySized
		senderLabel.show(sender: row.sender, date: large ? nil : row.dateText)
		let amountLine = large ? RowCaptionText.dateAndAmount(row) : row.amountText
			.map { NSAttributedString(string: $0) }
		amountLabel.attributedText = amountLine
		// UIKit sets a configuration inside the list's own animations, and a stack view counts each
		// hiding made inside an animation, so a label hidden twice stays hidden in its arrangement
		// after it shows again. Each label is therefore hidden or shown only when that changes, and
		// without an animation.
		UIView.performWithoutAnimation {
			Self.show(senderLabel, !row.sender.isEmpty || !large && row.dateText != nil)
			Self.show(amountLabel, amountLine != nil)
			Self.show(thirdLabel, !row.thirdLineText.isEmpty)
		}
		thirdLabel.textColor = switch row.thirdLineTone {
		case .secondary: .secondaryLabel
		case .accent: .tintColor
		case .failure: InterfacePalette.attentionText
		}
		if let search = content.markedSearch {
			thirdLabel.attributedText = LibrarySearch.markedExcerpt(row.thirdLineText, searchText: search)
		} else {
			thirdLabel.text = row.thirdLineText
		}
	}

	private static func show(_ label: UILabel, _ shown: Bool) {
		if label.isHidden == shown {
			label.isHidden = !shown
		}
	}
}

private extension DocumentRowContentView {
	func applyTrailing(_ trailing: RowTrailingIndicator, after previous: RowTrailingIndicator?, animated: Bool) {
		let showsAccessory = trailing != .absent
		accessory.isHidden = !showsAccessory
		accessorySize?.constant = showsAccessory ? Self.accessorySide : 0
		textBeforeAccessory?.constant = showsAccessory ? -12 : 0
		if case .activity = trailing {
			activityView.startAnimating()
		} else {
			activityView.stopAnimating()
		}
		if case let .progress(fraction) = trailing {
			progressView.isHidden = false
			let continuing = if case .progress? = previous {
				true
			} else {
				false
			}
			progressView.show(fraction: fraction, animated: animated && continuing)
		} else {
			progressView.isHidden = true
		}
		let symbol: (name: String, color: UIColor)? = switch trailing {
		case .done: ("checkmark.circle.fill", .tintColor)
		case .attention: ("exclamationmark.circle.fill", InterfacePalette.attentionText)
		case .absent, .activity, .progress: nil
		}
		guard let symbol else {
			symbolView.image = nil
			return
		}
		symbolView.tintColor = symbol.color
		guard let image = UIImage(systemName: symbol.name), animated, previous != trailing else {
			symbolView.image = UIImage(systemName: symbol.name)
			return
		}
		switch previous {
		case .progress?:
			// The ring ends as a full circle, which the checkmark replaces.
			symbolView.image = UIImage(systemName: "circle")
			symbolView.setSymbolImage(image, contentTransition: .replace)
		case .done?, .attention?:
			symbolView.setSymbolImage(image, contentTransition: .replace)
		case .absent?, .activity?, nil:
			symbolView.image = image
		}
	}
}
