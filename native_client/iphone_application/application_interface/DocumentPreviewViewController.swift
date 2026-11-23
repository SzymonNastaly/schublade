import ApplicationBindings
import ImageIO
import PDFKit
import UIKit

/// The picture a row's context menu lifts: the row's own picture scaled up at once, then the first
/// page of the original once it is on this iPhone.
final class DocumentPreviewViewController: UIViewController {
	private let gateway: ApplicationGateway
	private let document: DocumentIdentifier
	private let pictureView = UIImageView()

	init(gateway: ApplicationGateway, document: DocumentIdentifier, picture: UIImage?, width: CGFloat) {
		self.gateway = gateway
		self.document = document
		super.init(nibName: nil, bundle: nil)
		pictureView.image = picture
		// The proportions of an A4 page.
		preferredContentSize = CGSize(width: width, height: (width * 1.414).rounded())
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = InterfacePalette.paper
		pictureView.contentMode = .scaleAspectFill
		pictureView.clipsToBounds = true
		pictureView.frame = view.bounds
		pictureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		view.addSubview(pictureView)
		let size = preferredContentSize
		let scale = traitCollection.displayScale
		Task { [weak self, gateway, document] in
			guard let original = try? await gateway.original(document),
			      let page = await Self.firstPage(atPath: original.path, pointSize: size, scale: scale)
			else {
				return
			}
			self?.pictureView.contentMode = .scaleAspectFit
			self?.pictureView.image = page
		}
	}

	@concurrent
	private static func firstPage(atPath path: String, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
		let url = URL(filePath: path)
		if let page = PDFDocument(url: url)?.page(at: 0) {
			let pixels = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
			guard let drawn = page.thumbnail(of: pixels, for: .mediaBox).cgImage else {
				return nil
			}
			return UIImage(cgImage: drawn, scale: scale, orientation: .up)
		}
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: Int(max(pointSize.width, pointSize.height) * scale),
		]
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
		      let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
		else {
			return nil
		}
		return UIImage(cgImage: picture)
	}
}
