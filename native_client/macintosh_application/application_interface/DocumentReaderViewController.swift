import AppKit
import ApplicationBindings
import ApplicationPresentation
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
	private var loadedOriginalURL: URL?
	private var loadedPortableDocument: PDFDocument?
	private var loadedImage: NSImage?
	private var originalRefusal: RepresentationRefusal?
	private var loadedTextDocument: DocumentIdentifier?
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
		let detailUpdated = detail != activeDetail
		let termsChanged = searchTerms != activeSearchTerms

		activeDocument = document
		activeDetail = detail
		activeTab = tab
		activeSearchTerms = searchTerms
		headerView.render(detail: detail, hasSelection: document != nil, tab: tab)

		if documentChanged {
			resetLoadedMedia()
		}
		if let document {
			if documentChanged || (detailUpdated && loadedOriginalURL == nil && originalRefusal == nil) {
				loadOriginal(for: document, detail: detail)
			} else if termsChanged, let portableDocument = loadedPortableDocument {
				applySearchHighlights(to: portableDocument, terms: searchTerms)
			}
			if tab == .text, loadedTextDocument != document {
				loadText(for: document)
			}
		}
		updateDisplayedContent()
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
		loadedOriginalURL = nil
		loadedPortableDocument = nil
		loadedImage = nil
		originalRefusal = nil
		loadedTextDocument = nil
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
			showPlaceholder(for: ApplicationFailureWording.originalRefusalPlaceholder(refusal))
			return
		}
		if let portableDocument = loadedPortableDocument {
			if renderMode == .offscreenSnapshot {
				renderedPdfView.display(document: portableDocument)
				showOnly(.renderedPdf)
			} else {
				pdfView.document = portableDocument
				applySearchHighlights(to: portableDocument, terms: activeSearchTerms)
				showOnly(.pdf)
			}
			return
		}
		if let image = loadedImage {
			imageReaderView.display(image: image)
			showOnly(.image)
			return
		}
		placeholderView.render(title: "Loading Original…", detail: "", buttonTitle: nil, onAction: nil)
		showOnly(.placeholder)
	}

	private func displayTextTab() {
		if let refusal = textRefusal {
			showPlaceholder(for: ApplicationFailureWording.extractedTextRefusalPlaceholder(refusal))
			return
		}
		if let text = loadedText {
			textView.string = text
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
		pdfView.backgroundColor = .underPageBackgroundColor
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
			headerView.topAnchor.constraint(equalTo: view.topAnchor),
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
			loadedOriginalURL = URL(fileURLWithPath: localFile.path)
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
				originalRefusal = .ArchiveOutdated
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

	func applySearchHighlights(to document: PDFDocument, terms: [String]) {
		guard renderMode == .interactive else {
			return
		}
		let cleanTerms = terms.filter { $0.count >= 2 }
		guard !cleanTerms.isEmpty else {
			pdfView.highlightedSelections = nil
			return
		}
		var matches: [PDFSelection] = []
		for term in cleanTerms {
			matches.append(contentsOf: document.findString(
				term,
				withOptions: [.caseInsensitive, .diacriticInsensitive]
			))
			if matches.count >= 120 {
				break
			}
		}
		pdfView.highlightedSelections = matches.isEmpty ? nil : matches
	}
}
