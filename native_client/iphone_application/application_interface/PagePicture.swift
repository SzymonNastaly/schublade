import UIKit

/// The picture of a document's first page as the library's rows and the share sheet's tiles show
/// it: cut from its top edge, so the letterhead stays in view and no picture is letterboxed, and
/// drawn on paper, because a page is paper and a transparent picture would show the dark list
/// through it.
nonisolated enum PagePicture {
	/// The top of `picture` in the proportion of width to height, a wider picture cut at its sides.
	static func cut(_ picture: CGImage, proportion: Double) -> CGImage {
		let width = Double(picture.width)
		let height = Double(picture.height)
		let region = if width / height > proportion {
			CGRect(x: ((width - height * proportion) / 2).rounded(), y: 0, width: height * proportion, height: height)
		} else {
			CGRect(x: 0, y: 0, width: width, height: (width / proportion).rounded())
		}
		return picture.cropping(to: region.integral) ?? picture
	}

	/// `picture` drawn on paper to fill `size` points at `scale`.
	static func onPaper(_ picture: CGImage, size: CGSize, scale: CGFloat) -> UIImage {
		let format = UIGraphicsImageRendererFormat()
		format.scale = scale
		format.opaque = true
		return UIGraphicsImageRenderer(size: size, format: format).image { context in
			let bounds = CGRect(origin: .zero, size: size)
			InterfacePalette.paper.setFill()
			context.fill(bounds)
			UIImage(cgImage: picture).draw(in: bounds)
		}
	}
}

extension UIImageView {
	/// A page's picture with a hairline edge, or while there is none, `placeholder`, the name of a
	/// symbol, on a fill.
	func showPage(_ picture: UIImage?, placeholder: String) {
		if let picture {
			image = picture
			contentMode = .scaleAspectFill
			backgroundColor = InterfacePalette.paper
			layer.borderWidth = 0.5
			layer.borderColor = InterfacePalette.pictureEdge.cgColor
		} else {
			image = UIImage(systemName: placeholder)
			contentMode = .center
			backgroundColor = .secondarySystemFill
			layer.borderWidth = 0
		}
	}
}
