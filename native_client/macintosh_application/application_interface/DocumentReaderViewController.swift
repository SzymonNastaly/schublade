import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation
import PDFKit

/// Right-center reader pane showing the header and either the PDF, raster image, placeholder,
/// or selectable extracted Markdown text.
final class DocumentReaderViewController: NSViewController {
	private enum ContentPane {
		case pdf
		case renderedPdf
		case image
		case text
		case placeholder
	}

	private let queries: any LibraryQueries
	private let renderMode: InterfaceRenderMode
	private let onTabChanged: (ReaderTab) -> Void
	private let onReplaceToken: () -> Void

	private let headerView = ReaderHeaderView()
	private let contentHost = NSView()
	private let pdfView = PDFView()
	private let renderedPdfView = RenderedPortableDocumentView()
	private let imageReaderView = ImageReaderView()
	private let textScrollView = NSScrollView()
	private let textView = NSTextView()
	private let placeholderView = ReaderPlaceholderView()

	private var activeTab: ReaderTab = .original
	private var activeDocument: DocumentIdentifier?
	private var activeDetail: DocumentDetailPresentation?
	private var activeSearchTerms: [String] = []
	private var requestedOriginalKind: OriginalKind?
	private var loadedPortableDocument: PDFDocument?
	private var loadedImage: NSImage?
	private var originalRefusal: RepresentationRefusal?
	private var originalUnreadable = false
	private var loadedTextDocument: DocumentIdentifier?
	private var requestedTextDocument: DocumentIdentifier?
	private var displayedTextDocument: DocumentIdentifier?
	private var highlightedTerms: [String]?
	private var loadedText: String?
	private var textRefusal: RepresentationRefusal?
	private var newestOriginalRequest: UInt64 = 0
	private var newestTextRequest: UInt64 = 0

	var focusTargetView: NSView {
		switch activeTab {
		case .original:
			renderMode == .offscreenSnapshot ? renderedPdfView : pdfView
		case .text:
			textView
		}
	}

	init(
		queries: any LibraryQueries,
		renderMode: InterfaceRenderMode = .interactive,
		onTabChanged: @escaping (ReaderTab) -> Void,
		onReplaceToken: @escaping () -> Void
	) {
		self.queries = queries
		self.renderMode = renderMode
		self.onTabChanged = onTabChanged
		self.onReplaceToken = onReplaceToken
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		headerView.onTabChanged = onTabChanged
		configureContentPanes()
		configureLayout()
		updateDisplayedContent()
	}

	func render(
		document: DocumentIdentifier?,
		detail: DocumentDetailPresentation?,
		tab: ReaderTab,
		searchTerms: [String]
	) {
		let documentChanged = document != activeDocument

		activeDocument = document
		activeDetail = detail
		activeTab = tab
		activeSearchTerms = searchTerms
		headerView.render(detail: detail, hasSelection: document != nil, tab: tab)

		if documentChanged {
			resetLoadedMedia()
		}
		if let document {
			// The kind arrives with the detail, after the selection, and changes once an email is printed.
			let kind = detail?.originalKind
			let kindChanged = kind != nil && requestedOriginalKind != nil && kind != requestedOriginalKind
			if documentChanged || kindChanged {
				loadOriginal(for: document, detail: detail)
			}
			if tab == .text, loadedTextDocument != document, requestedTextDocument != document {
				loadText(for: document)
			}
		}
		updateDisplayedContent()
	}

	/// Asks again for what the copy may now hold: an original or a text that was refused before.
	func contentRevisionChanged() {
		guard let document = activeDocument else {
			return
		}
		if originalRefusal != nil {
			loadOriginal(for: document, detail: activeDetail)
		}
		if textRefusal != nil {
			loadedTextDocument = nil
			textRefusal = nil
			if activeTab == .text {
				loadText(for: document)
			}
		}
	}

	func reloadCurrentDocumentRepresentations() {
		guard let document = activeDocument else {
			return
		}
		loadOriginal(for: document, detail: activeDetail)
		if activeTab == .text {
			loadText(for: document)
		}
	}

	private func resetLoadedMedia() {
		newestOriginalRequest &+= 1
		newestTextRequest &+= 1
		requestedOriginalKind = nil
		loadedPortableDocument = nil
		loadedImage = nil
		originalRefusal = nil
		originalUnreadable = false
		loadedTextDocument = nil
		requestedTextDocument = nil
		displayedTextDocument = nil
		highlightedTerms = nil
		loadedText = nil
		textRefusal = nil
		pdfView.document = nil
		renderedPdfView.display(document: nil)
		imageReaderView.display(image: nil)
		textView.string = ""
	}

	private func updateDisplayedContent() {
		guard activeDocument != nil else {
			placeholderView.render(title: "No Document Selected", detail: "", buttonTitle: nil, onAction: nil)
			showOnly(.placeholder)
			return
		}
		if activeTab == .text {
			displayTextTab()
		} else {
			displayOriginalTab()
		}
	}

	private func displayOriginalTab() {
		if let refusal = originalRefusal {
			let device = MacintoshDevice.wording
			showPlaceholder(for: LibraryFailureWording.originalRefusalPlaceholder(refusal, device: device))
			return
		}
		if originalUnreadable {
			showPlaceholder(for: LibraryFailureWording.unreadableOriginalPlaceholder)
			return
		}
		// A render follows every status, so each pane is given its content only when it changed:
		// assigning it again would drop the selection, the zoom, and the scroll position.
		if let portableDocument = loadedPortableDocument {
			if renderMode == .offscreenSnapshot {
				renderedPdfView.display(document: portableDocument)
				showOnly(.renderedPdf)
			} else {
				if pdfView.document !== portableDocument {
					pdfView.document = portableDocument
					highlightedTerms = nil
				}
				if highlightedTerms != activeSearchTerms {
					highlightedTerms = activeSearchTerms
					pdfView.highlightedSelections = SearchWordHighlighting.selections(
						in: portableDocument,
						terms: activeSearchTerms
					)
				}
				showOnly(.pdf)
			}
			return
		}
		if let image = loadedImage {
			if imageReaderView.image !== image {
				imageReaderView.display(image: image)
			}
			showOnly(.image)
			return
		}
		placeholderView.render(title: "Loading Original…", detail: "", buttonTitle: nil, onAction: nil)
		showOnly(.placeholder)
	}

	private func displayTextTab() {
		if let refusal = textRefusal {
			showPlaceholder(for: LibraryFailureWording.extractedTextRefusalPlaceholder(refusal))
			return
		}
		if let text = loadedText {
			if displayedTextDocument != loadedTextDocument {
				displayedTextDocument = loadedTextDocument
				textView.string = text
			}
			showOnly(.text)
			return
		}
		placeholderView.render(title: "Loading Text…", detail: "", buttonTitle: nil, onAction: nil)
		showOnly(.placeholder)
	}

	private func showOnly(_ pane: ContentPane) {
		pdfView.isHidden = pane != .pdf
		renderedPdfView.isHidden = pane != .renderedPdf
		imageReaderView.isHidden = pane != .image
		textScrollView.isHidden = pane != .text
		placeholderView.isHidden = pane != .placeholder
	}
}

private extension DocumentReaderViewController {
	func configureContentPanes() {
		pdfView.autoScales = true
		pdfView.displayMode = .singlePageContinuous
		pdfView.displaysPageBreaks = true
		pdfView.backgroundColor = InterfacePalette.readerBackdrop
		pdfView.setAccessibilityIdentifier(InterfaceIdentifier.readerPortableDocumentView)

		textView.isEditable = false
		textView.isSelectable = true
		textView.isRichText = false
		textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
		textView.textContainerInset = NSSize(width: 24, height: 20)
		textView.autoresizingMask = [.width]
		textView.setAccessibilityIdentifier(InterfaceIdentifier.readerTextView)

		textScrollView.documentView = textView
		textScrollView.hasVerticalScroller = true
		textScrollView.drawsBackground = true

		for pane in [pdfView, renderedPdfView, imageReaderView, textScrollView, placeholderView] {
			pane.translatesAutoresizingMaskIntoConstraints = false
			pane.isHidden = true
			contentHost.addSubview(pane)
			NSLayoutConstraint.activate([
				pane.topAnchor.constraint(equalTo: contentHost.topAnchor),
				pane.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
				pane.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
				pane.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
			])
		}
	}

	func configureLayout() {
		headerView.translatesAutoresizingMaskIntoConstraints = false
		contentHost.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(headerView)
		view.addSubview(contentHost)

		NSLayoutConstraint.activate([
			// Below the toolbar, which the window's full-size content would otherwise put over it.
			headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			contentHost.topAnchor.constraint(equalTo: headerView.bottomAnchor),
			contentHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			contentHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			contentHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])
	}

	func loadOriginal(for document: DocumentIdentifier, detail: DocumentDetailPresentation?) {
		newestOriginalRequest &+= 1
		let requestNumber = newestOriginalRequest
		originalUnreadable = false
		requestedOriginalKind = detail?.originalKind
		if detail?.originalKind == .unprintedEmail {
			originalRefusal = .NotAvailableYet
			updateDisplayedContent()
			return
		}
		Task {
			await performLoadOriginal(requestNumber: requestNumber, document: document)
		}
	}

	func performLoadOriginal(requestNumber: UInt64, document: DocumentIdentifier) async {
		do {
			let localFile = try await queries.original(document)
			guard requestNumber == newestOriginalRequest, document == activeDocument else {
				return
			}
			originalRefusal = nil
			if let portableDocument = await PortableDocumentLoader.openPortableDocument(atPath: localFile.path) {
				guard requestNumber == newestOriginalRequest, document == activeDocument else {
					return
				}
				loadedPortableDocument = portableDocument
				loadedImage = nil
			} else if let cgImage = await PortableDocumentLoader.decodeImage(atPath: localFile.path) {
				guard requestNumber == newestOriginalRequest, document == activeDocument else {
					return
				}
				loadedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
				loadedPortableDocument = nil
			} else {
				guard requestNumber == newestOriginalRequest, document == activeDocument else {
					return
				}
				originalUnreadable = true
			}
			updateDisplayedContent()
		} catch {
			guard requestNumber == newestOriginalRequest, document == activeDocument else {
				return
			}
			originalRefusal = error
			updateDisplayedContent()
		}
	}

	func loadText(for document: DocumentIdentifier) {
		newestTextRequest &+= 1
		let requestNumber = newestTextRequest
		requestedTextDocument = document
		Task {
			await performLoadText(requestNumber: requestNumber, document: document)
		}
	}

	func performLoadText(requestNumber: UInt64, document: DocumentIdentifier) async {
		do {
			let markdown = try await queries.extractedText(document)
			guard requestNumber == newestTextRequest, document == activeDocument else {
				return
			}
			loadedTextDocument = document
			loadedText = markdown
			textRefusal = nil
			updateDisplayedContent()
		} catch {
			guard requestNumber == newestTextRequest, document == activeDocument else {
				return
			}
			loadedTextDocument = document
			textRefusal = error
			updateDisplayedContent()
		}
	}

	func showPlaceholder(for placeholder: RepresentationPlaceholder) {
		let buttonTitle: String?
		let action: (() -> Void)?
		if placeholder.allowsTokenReplacement {
			buttonTitle = "Replace Token…"
			action = { [weak self] in self?.onReplaceToken() }
		} else if placeholder.canRetry {
			buttonTitle = "Try Again"
			action = { [weak self] in self?.reloadCurrentDocumentRepresentations() }
		} else {
			buttonTitle = nil
			action = nil
		}
		placeholderView.render(
			title: placeholder.title,
			detail: placeholder.detail,
			buttonTitle: buttonTitle,
			onAction: action
		)
		showOnly(.placeholder)
	}
}
