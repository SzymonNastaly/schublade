import ApplicationBindings
import ImageIO
import LibraryPresentation
import PDFKit
import UIKit

final class DocumentOriginalViewController: UIViewController {
	enum OriginalState {
		case loading
		case portableDocument(PDFDocument)
		case picture(UIImage)
		case unavailable(RepresentationPlaceholder)
	}

	private let gateway: ApplicationGateway
	private let document: DocumentIdentifier
	/// Read again with every detail, because the archive prints an email after the page opened.
	private var kind: OriginalKind
	/// The document's page in the archive while the document failed, where a person can retry it.
	private var failedDocumentPage: URL?
	private(set) var state = OriginalState.loading
	private var newestRequest: UInt64 = 0
	private var appeared = false
	/// The document whose first page was placed below the bars.
	private weak var placedDocument: PDFDocument?
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

	/// The kind and the failure of the newest detail. An email the archive has printed since the
	/// last one loads its PDF.
	func show(kind: OriginalKind, failedDocumentPage: URL?) {
		let printed = self.kind == .unprintedEmail && kind != .unprintedEmail
		self.kind = kind
		let pageChanged = self.failedDocumentPage != failedDocumentPage
		self.failedDocumentPage = failedDocumentPage
		if printed, isViewLoaded {
			load()
		} else if pageChanged, case let .unavailable(placeholder) = state {
			show(.unavailable(placeholder))
		}
	}

	override func viewIsAppearing(_ animated: Bool) {
		super.viewIsAppearing(animated)
		showPortableDocumentIfAppearing()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		appeared = true
		placeFirstPageBelowBars()
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)
		appeared = false
	}

	/// PDFView leaves a new document at the offset zero, under the bars, when the bars reached the
	/// page after it, as they do in the zoom transition. Each document is placed once, so a page the
	/// person returns to stays where it was read.
	private func placeFirstPageBelowBars() {
		guard appeared, let document = portableDocumentView.document, placedDocument !== document,
		      let pages = portableDocumentView.subviews.lazy.compactMap({ $0 as? UIScrollView }).first
		else {
			return
		}
		placedDocument = document
		view.layoutIfNeeded()
		pages.setContentOffset(CGPoint(x: pages.contentOffset.x, y: -pages.adjustedContentInset.top), animated: false)
	}

	/// PDFView places a new document's first page below the bars it finds at that moment, so a page
	/// that loads under the text page, which opened above it from a search, gets its document once
	/// it appears.
	private func showPortableDocumentIfAppearing() {
		guard case let .portableDocument(document) = state, view.window != nil,
		      portableDocumentView.document !== document
		else {
			return
		}
		portableDocumentView.document = document
		placeFirstPageBelowBars()
	}

	/// PDFView leaves its safe area to its scroll view's top alone and ignores a raised bottom, so the
	/// height the details sheet covers is given to that scroll view as an inset of its own. A page
	/// then scrolls its last lines above the sheet.
	override func viewSafeAreaInsetsDidChange() {
		super.viewSafeAreaInsetsDidChange()
		let pages = portableDocumentView.subviews.lazy.compactMap { $0 as? UIScrollView }.first
		pages?.contentInset.bottom = additionalSafeAreaInsets.bottom
	}

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
				next = await Self.open(file, maximumPixelSize: largestPictureNeeded())
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
		case .portableDocument:
			contentUnavailableConfiguration = nil
			showPortableDocumentIfAppearing()
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
			var buttons: [(title: String, action: UIAction)] = []
			if placeholder.canRetry {
				buttons.append(("Try Again", UIAction { [weak self] _ in self?.load() }))
			}
			if let failedDocumentPage {
				buttons.append(("Open in Browser", UIAction { _ in UIApplication.shared.open(failedDocumentPage) }))
			}
			if let first = buttons.first {
				configuration.button = .plain()
				configuration.button.title = first.title
				configuration.buttonProperties.primaryAction = first.action
			}
			if buttons.count > 1 {
				configuration.secondaryButton = .plain()
				configuration.secondaryButton.title = buttons[1].title
				configuration.secondaryButtonProperties.primaryAction = buttons[1].action
			}
			contentUnavailableConfiguration = configuration
		}
	}

	/// The longest side in pixels that a picture shows at its largest zoom on this screen, because a
	/// photograph of 48 megapixels decoded whole takes about 195 MB.
	private func largestPictureNeeded() -> Int {
		let screenSide = max(view.bounds.width, view.bounds.height) * traitCollection.displayScale
		return Int(max(screenSide, 1024) * pictureView.maximumZoomScale)
	}

	@concurrent
	private static func open(_ file: LocalFile, maximumPixelSize: Int) async -> OriginalState {
		let url = URL(filePath: file.path)
		if let document = PDFDocument(url: url) {
			return .portableDocument(document)
		}
		// Only a thumbnail applies the EXIF orientation, so a phone's photograph stands upright.
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
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
