import UIKit

/// What the sheet shows under its bar: a row of tiles, a checkmark, a headline, the destination, and
/// a footnote. The sheet is as tall as the screen, so the tiles sit a little above the middle and stay
/// there while the words change. Content taller than the sheet starts at its top and scrolls.
final class ShareSheetView: UIView {
	struct Words: Equatable {
		var headline: String
		var destination: String?
		var footnote: String?
		var handedOver = false
	}

	private(set) var tiles: [ShareTile]
	private let scrollView = UIScrollView()
	private let content = UIStackView()
	private let tileLayout = UICollectionViewFlowLayout()
	private lazy var tilesView = UICollectionView(frame: .zero, collectionViewLayout: tileLayout)
	private lazy var tilesHeight = tilesView.heightAnchor.constraint(equalToConstant: tileItemSize.height)
	private lazy var contentTop = content.topAnchor.constraint(
		equalTo: scrollView.contentLayoutGuide.topAnchor,
		constant: Self.margin
	)
	private static let margin: CGFloat = 24
	private let symbolView = UIImageView()
	private let headlineLabel = UILabel()
	private let destinationLabel = UILabel()
	private let footnoteLabel = UILabel()

	init(tiles: [ShareTile]) {
		self.tiles = tiles
		super.init(frame: .zero)
		tileLayout.scrollDirection = .horizontal
		tileLayout.minimumLineSpacing = ShareTileSize.spacing
		tilesView.backgroundColor = .clear
		tilesView.showsHorizontalScrollIndicator = false
		tilesView.dataSource = self
		tilesView.register(ShareTileCell.self, forCellWithReuseIdentifier: "tile")

		content.addArrangedSubview(tilesView)
		content.addArrangedSubview(wordsStack())
		content.axis = .vertical
		content.spacing = 24
		content.translatesAutoresizingMaskIntoConstraints = false

		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.contentInsetAdjustmentBehavior = .never
		scrollView.addSubview(content)
		addSubview(scrollView)
		// The scrolled height is the sheet's, or the content's once a large text size outgrows the sheet.
		let space = scrollView.contentLayoutGuide
		let frame = scrollView.frameLayoutGuide
		let filled = space.heightAnchor.constraint(equalTo: frame.heightAnchor)
		filled.priority = .defaultLow
		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
			space.widthAnchor.constraint(equalTo: frame.widthAnchor),
			space.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
			filled,
			tilesHeight,
			contentTop,
			content.leadingAnchor.constraint(equalTo: space.leadingAnchor),
			content.trailingAnchor.constraint(equalTo: space.trailingAnchor),
			content.bottomAnchor.constraint(lessThanOrEqualTo: space.bottomAnchor, constant: -Self.margin),
		])
		registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
			view.setNeedsLayout()
		}
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	func show(_ words: Words) {
		headlineLabel.text = words.headline
		destinationLabel.text = words.destination
		footnoteLabel.text = words.footnote
		destinationLabel.isHidden = words.destination == nil
		footnoteLabel.isHidden = words.footnote == nil
		if symbolView.isHidden == words.handedOver {
			symbolView.isHidden = !words.handedOver
			if words.handedOver, !UIAccessibility.isReduceMotionEnabled {
				symbolView.addSymbolEffect(.bounce, options: .nonRepeating)
			}
		}
		setNeedsLayout()
	}

	func update(_ index: Int, _ change: (inout ShareTile) -> Void) {
		change(&tiles[index])
		if let cell = tilesView.cellForItem(at: IndexPath(item: index, section: 0)) as? ShareTileCell {
			cell.show(tiles[index], large: tiles.count == 1)
		}
	}

	func reveal(_ index: Int) {
		tilesView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: true)
	}

	override func layoutSubviews() {
		// A row narrower than the sheet sits in its middle, and a wider one starts 20 points in.
		let size = tileItemSize
		let count = CGFloat(tiles.count)
		let rowWidth = count * size.width + max(count - 1, 0) * ShareTileSize.spacing
		let inset = max(20, ((bounds.width - rowWidth) / 2).rounded(.down))
		let insets = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
		if tileLayout.itemSize != size || tileLayout.sectionInset != insets {
			tileLayout.itemSize = size
			tileLayout.sectionInset = insets
			tilesHeight.constant = size.height
		}
		let height = content.systemLayoutSizeFitting(
			CGSize(width: bounds.width, height: 0),
			withHorizontalFittingPriority: .required,
			verticalFittingPriority: .fittingSizeLevel
		).height
		let centred = (bounds.height - size.height) / 2 - 2 * Self.margin
		let top = max(Self.margin, min(centred, bounds.height - height - Self.margin)).rounded()
		if contentTop.constant != top {
			contentTop.constant = top
		}
		super.layoutSubviews()
	}

	private func wordsStack() -> UIStackView {
		symbolView.image = UIImage(systemName: "checkmark.circle.fill")
		symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle)
		symbolView.contentMode = .center
		symbolView.isHidden = true
		Self.style(headlineLabel, .headline, color: .label)
		Self.style(destinationLabel, .subheadline, color: .secondaryLabel)
		Self.style(footnoteLabel, .footnote, color: .secondaryLabel)

		let text = UIStackView(arrangedSubviews: [symbolView, headlineLabel, destinationLabel, footnoteLabel])
		text.axis = .vertical
		text.spacing = 4
		text.setCustomSpacing(10, after: symbolView)
		text.setCustomSpacing(16, after: destinationLabel)
		text.isLayoutMarginsRelativeArrangement = true
		text.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
		return text
	}

	/// A tile with its name line when any file is a document, so every tile of the row is as tall. One
	/// tile alone is as wide as the sheet, so its name has room at a large text size.
	private var tileItemSize: CGSize {
		let picture = ShareTileSize.of(count: tiles.count)
		let width = tiles.count == 1 ? max(bounds.width - 40, picture.width) : picture.width
		guard tiles.contains(where: { !$0.isPicture }) else {
			return CGSize(width: width, height: picture.height)
		}
		let nameLine = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection).lineHeight
		return CGSize(width: width, height: picture.height + ShareTileSize.nameSpacing + nameLine.rounded(.up))
	}

	private static func style(_ label: UILabel, _ textStyle: UIFont.TextStyle, color: UIColor) {
		label.font = .preferredFont(forTextStyle: textStyle)
		label.adjustsFontForContentSizeCategory = true
		label.textColor = color
		label.textAlignment = .center
		label.numberOfLines = 0
	}
}

extension ShareSheetView: UICollectionViewDataSource {
	func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
		tiles.count
	}

	func collectionView(
		_ collectionView: UICollectionView,
		cellForItemAt indexPath: IndexPath
	) -> UICollectionViewCell {
		let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "tile", for: indexPath)
		(cell as? ShareTileCell)?.show(tiles[indexPath.item], large: tiles.count == 1)
		return cell
	}
}
