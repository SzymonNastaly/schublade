import ApplicationBindings
import ImageIO
import LibraryPresentation
import PDFKit
import UIKit

/// The original of one document: a PDF in `PDFView`, a picture that zooms, or why neither shows. An
/// original the cache lacks is downloaded first, and one that could not be is read again when the
/// copy changes or a person tries again.
final class DocumentOriginalViewController: UIViewController {
	enum OriginalState {
		case loading
		case portableDocument(PDFDocument)
		case picture(UIImage)
		case unavailable(RepresentationPlaceholder)
	}

	private let gateway: ApplicationGateway
	private let document: DocumentIdentifier
	private let kind: OriginalKind
	private(set) var state = OriginalState.loading
	private var newestRequest: UInt64 = 0
	let portableDocumentView = PDFView()
	private let pictureView = ZoomingPictureView()

	init(gateway: ApplicationGateway, document: DocumentIdentifier, kind: OriginalKind) {
		self.gateway = gateway
		self.document = document
		self.kind = kind
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = InterfacePalette.readerBackdrop
		portableDocumentView.displayMode = .singlePageContinuous
		portableDocumentView.displayDirection = .vertical
		portableDocumentView.autoScales = true
		portableDocumentView.pageShadowsEnabled = true
		portableDocumentView.backgroundColor = InterfacePalette.readerBackdrop
		portableDocumentView.accessibilityIdentifier = "document.original.pdf"
		for shown in [portableDocumentView, pictureView] as [UIView] {
			shown.frame = view.bounds
			shown.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			shown.isHidden = true
			view.addSubview(shown)
		}
		load()
	}

	/// An original that could not be shown is asked for again, as after the archive became
	/// reachable or finished preparing it.
	func contentRevisionChanged() {
		if case .unavailable = state {
			load()
		}
	}

	private func load() {
		newestRequest &+= 1
		let request = newestRequest
		// The archive prints an email to a PDF before it has an original to show.
		guard kind != .unprintedEmail else {
			show(.unavailable(LibraryFailureWording.originalRefusalPlaceholder(
				.NotAvailableYet,
				device: IphoneDevice.wording
			)))
			return
		}
		if case .unavailable = state {
			show(.loading)
		}
		Task {
			let next: OriginalState
			do throws(RepresentationRefusal) {
				let file = try await gateway.original(document)
				next = await Self.open(file)
			} catch {
				next = .unavailable(LibraryFailureWording.originalRefusalPlaceholder(
					error,
					device: IphoneDevice.wording
				))
			}
			guard request == newestRequest else {
				return
			}
			show(next)
		}
	}

	private func show(_ next: OriginalState) {
		state = next
		portableDocumentView.isHidden = true
		pictureView.isHidden = true
		switch next {
		case .loading:
			var loading = UIContentUnavailableConfiguration.loading()
			loading.text = "Loading Original…"
			contentUnavailableConfiguration = loading
		case let .portableDocument(document):
			contentUnavailableConfiguration = nil
			if portableDocumentView.document !== document {
				portableDocumentView.document = document
			}
			portableDocumentView.isHidden = false
		case let .picture(picture):
			contentUnavailableConfiguration = nil
			pictureView.show(picture)
			pictureView.isHidden = false
		case let .unavailable(placeholder):
			var configuration = UIContentUnavailableConfiguration.empty()
			configuration.image = UIImage(systemName: "doc.text.magnifyingglass")
			configuration.text = placeholder.title
			configuration.secondaryText = placeholder.detail
			if placeholder.canRetry {
				configuration.button = .plain()
				configuration.button.title = "Try Again"
				configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
			}
			contentUnavailableConfiguration = configuration
		}
	}

	/// Opens a PDF, or decodes a picture upright, away from the main actor.
	@concurrent
	private static func open(_ file: LocalFile) async -> OriginalState {
		let url = URL(filePath: file.path)
		if let document = PDFDocument(url: url) {
			return .portableDocument(document)
		}
		// Only a thumbnail applies the EXIF orientation, so a phone's photograph stands upright.
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
		]
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
		      let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
		else {
			return .unavailable(LibraryFailureWording.unreadableOriginalPlaceholder)
		}
		return .picture(UIImage(cgImage: picture))
	}
}

/// A picture that fits the screen and zooms up to four times, by pinching or a double tap.
final class ZoomingPictureView: UIScrollView, UIScrollViewDelegate {
	private let imageView = UIImageView()

	override init(frame: CGRect) {
		super.init(frame: frame)
		delegate = self
		minimumZoomScale = 1
		maximumZoomScale = 4
		showsHorizontalScrollIndicator = false
		imageView.contentMode = .scaleAspectFit
		imageView.isUserInteractionEnabled = true
		addSubview(imageView)
		let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
		doubleTap.numberOfTapsRequired = 2
		addGestureRecognizer(doubleTap)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	func show(_ picture: UIImage) {
		guard imageView.image !== picture else {
			return
		}
		imageView.image = picture
		zoomScale = 1
		setNeedsLayout()
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		if zoomScale == 1 {
			imageView.frame = CGRect(origin: .zero, size: bounds.inset(by: adjustedContentInset).size)
			contentSize = imageView.frame.size
		}
	}

	func viewForZooming(in _: UIScrollView) -> UIView? {
		imageView
	}

	@objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
		if zoomScale > 1 {
			setZoomScale(1, animated: true)
		} else {
			let point = gesture.location(in: imageView)
			zoom(
				to: CGRect(
					x: point.x - bounds.width / 4,
					y: point.y - bounds.height / 4,
					width: bounds.width / 2,
					height: bounds.height / 2
				),
				animated: true
			)
		}
	}
}
