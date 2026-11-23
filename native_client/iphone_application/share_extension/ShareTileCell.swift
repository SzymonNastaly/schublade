import QuickLookThumbnailing
import UIKit

/// One file of a share as the sheet shows it: its picture, its name, and what became of it.
struct ShareTile: Hashable {
	enum Mark: Hashable {
		case none
		/// Its upload has started, or the archive has already answered it.
		case started
		/// The sheet could not read it.
		case unread
	}

	/// The file's name, which only a document shows under its picture, nil until it is known.
	var name: String?
	let isPicture: Bool
	var picture: UIImage?
	var mark = Mark.none
}

/// The size of a tile's picture: one large picture alone, or a row of smaller ones. Both are cut to
/// 10:13, about the shape of a page with its top kept.
enum ShareTileSize {
	static let single = CGSize(width: 200, height: 260)
	static let several = CGSize(width: 120, height: 156)
	static let spacing: CGFloat = 12
	static let nameSpacing: CGFloat = 6

	static func of(count: Int) -> CGSize {
		count == 1 ? single : several
	}

	/// The picture of a copied file, rendered by Quick Look outside the extension's memory and cut
	/// from its top to the tile's shape on white, because a page is paper.
	static func picture(of file: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
		// A page is narrower than a tile, so Quick Look fits it in a box tall enough that its width
		// fills the tile; a wide picture is cut at its sides.
		let side = max(size.width, size.height) * 1.5
		let request = QLThumbnailGenerator.Request(
			fileAt: file,
			size: CGSize(width: side, height: side),
			scale: scale,
			representationTypes: .thumbnail
		)
		guard let rendered = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
		else {
			return nil
		}
		return framed(rendered, size: size, scale: scale)
	}

	private static func framed(_ picture: CGImage, size: CGSize, scale: CGFloat) -> UIImage {
		let proportion = size.width / size.height
		let width = Double(picture.width)
		let height = Double(picture.height)
		let cut = if width / height > proportion {
			CGRect(x: ((width - height * proportion) / 2).rounded(), y: 0, width: height * proportion, height: height)
		} else {
			CGRect(x: 0, y: 0, width: width, height: (width / proportion).rounded())
		}
		let cropped = picture.cropping(to: cut.integral) ?? picture
		let format = UIGraphicsImageRendererFormat()
		format.scale = scale
		format.opaque = true
		return UIGraphicsImageRenderer(size: size, format: format).image { context in
			let bounds = CGRect(origin: .zero, size: size)
			InterfacePalette.paper.setFill()
			context.fill(bounds)
			UIImage(cgImage: cropped).draw(in: bounds)
		}
	}
}

final class ShareTileCell: UICollectionViewCell {
	private let pictureView = UIImageView()
	private let markView = UIImageView()
	private let nameLabel = UILabel()
	private lazy var pictureWidth = pictureView.widthAnchor.constraint(equalToConstant: ShareTileSize.several.width)

	override init(frame: CGRect) {
		super.init(frame: frame)
		pictureView.layer.cornerRadius = 8
		pictureView.layer.cornerCurve = .continuous
		pictureView.clipsToBounds = true
		pictureView.tintColor = .tertiaryLabel
		pictureView.translatesAutoresizingMaskIntoConstraints = false
		markView.translatesAutoresizingMaskIntoConstraints = false
		nameLabel.font = .preferredFont(forTextStyle: .caption1)
		nameLabel.adjustsFontForContentSizeCategory = true
		nameLabel.textColor = .secondaryLabel
		nameLabel.textAlignment = .center
		nameLabel.lineBreakMode = .byTruncatingMiddle
		nameLabel.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(pictureView)
		contentView.addSubview(markView)
		contentView.addSubview(nameLabel)
		NSLayoutConstraint.activate([
			pictureView.topAnchor.constraint(equalTo: contentView.topAnchor),
			pictureView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			pictureWidth,
			pictureView.heightAnchor.constraint(equalTo: pictureView.widthAnchor, multiplier: 13.0 / 10.0),
			markView.trailingAnchor.constraint(equalTo: pictureView.trailingAnchor, constant: -6),
			markView.bottomAnchor.constraint(equalTo: pictureView.bottomAnchor, constant: -6),
			nameLabel.topAnchor.constraint(equalTo: pictureView.bottomAnchor, constant: ShareTileSize.nameSpacing),
			nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
		])
		isAccessibilityElement = true
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	func show(_ tile: ShareTile, large: Bool) {
		pictureWidth.constant = large ? ShareTileSize.single.width : ShareTileSize.several.width
		if let picture = tile.picture {
			pictureView.image = picture
			pictureView.contentMode = .scaleToFill
			pictureView.backgroundColor = InterfacePalette.paper
			pictureView.layer.borderWidth = 0.5
			pictureView.layer.borderColor = InterfacePalette.pictureEdge.cgColor
		} else {
			pictureView.image = UIImage(systemName: tile.isPicture ? "photo" : "doc.richtext")
			pictureView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
				textStyle: large ? .largeTitle : .title2
			)
			pictureView.contentMode = .center
			pictureView.backgroundColor = .secondarySystemFill
			pictureView.layer.borderWidth = 0
		}
		nameLabel.text = tile.isPicture ? nil : tile.name
		let markSize = UIImage.SymbolConfiguration(pointSize: large ? 28 : 22, weight: .semibold)
		switch tile.mark {
		case .none:
			markView.image = nil
		case .started:
			markView.image = UIImage(
				systemName: "checkmark.circle.fill",
				withConfiguration: markSize
					.applying(UIImage.SymbolConfiguration(paletteColors: [.white, .tintColor]))
			)
		case .unread:
			markView.image = UIImage(
				systemName: "exclamationmark.circle.fill",
				withConfiguration: markSize
					.applying(UIImage.SymbolConfiguration(paletteColors: [.white, InterfacePalette.attentionText]))
			)
		}
		accessibilityLabel = tile.name ?? "Picture"
		accessibilityValue = switch tile.mark {
		case .none: nil
		case .started: "Sending"
		case .unread: "Not read"
		}
	}
}
