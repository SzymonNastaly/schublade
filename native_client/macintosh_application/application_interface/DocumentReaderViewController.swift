import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation
import PDFKit

/// The reader: the original or the extracted text from the window's top edge to its bottom, so the
/// page passes under the toolbar's glass, or an empty state in their place. A search's words are
/// marked in whichever the reader shows, and Find Next and Find Previous step through them.
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
	private let onShowTextForMatch: (DocumentIdentifier) -> Void
	let onOpenOriginal: () -> Void
	private let onReplaceToken: () -> Void

	let pdfView = PDFView()
	let renderedPdfView = RenderedPortableDocumentView()
	let imageReaderView = ImageReaderView()
	let textScrollView = NSScrollView()
	let textView = ExtractedTextView()
	private(set) lazy var placeholderView = EmptyStateView { [weak self] action in
		switch action {
		case .replaceToken: self?.onReplaceToken()
		case .tryAgain: self?.reloadCurrentDocumentRepresentations()
		case .addFolder, .searchAllDocuments: break
		}
	}

	private var shownPane: ContentPane?
	private var activeTab: ReaderTab = .original
	private var activeDocument: DocumentIdentifier?
	private var activeDetail: DocumentDetailPresentation?
	private var activeSearchTerms: [String] = []
	private var requestedOriginalKind: OriginalKind?
	private(set) var loadedOriginal: (document: DocumentIdentifier, file: URL)?
	private var loadedPortableDocument: PDFDocument?
	private var loadedImage: NSImage?
	private var originalRefusal: RepresentationRefusal?
	private var originalUnreadable = false
	private var loadedTextDocument: DocumentIdentifier?
	private var requestedTextDocument: DocumentIdentifier?
	private var loadedText: String?
	private var textRefusal: RepresentationRefusal?
	private var newestOriginalRequest: UInt64 = 0
	private var newestTextRequest: UInt64 = 0

	private lazy var marks = ReaderSearchMarks(
		pdfView: pdfView,
		textView: textView,
		showsFindIndicator: renderMode == .interactive
	)
	/// The document and search for which the reader already chose the tab that shows the matches.
	private var tabChosenForMatches: ReaderSearchMarks.Placement?

	/// The views that take the keyboard in the order Tab reaches them; only the shown one can.
	var keyViews: [NSView] {
		[pdfView, textView, placeholderView.actionControl]
	}

	init(
		queries: any LibraryQueries,
		renderMode: InterfaceRenderMode = .interactive,
		onShowTextForMatch: @escaping (DocumentIdentifier) -> Void,
		onOpenOriginal: @escaping () -> Void,
		onReplaceToken: @escaping () -> Void
	) {
		self.queries = queries
		self.renderMode = renderMode
		self.onShowTextForMatch = onShowTextForMatch
		self.onOpenOriginal = onOpenOriginal
		self.onReplaceToken = onReplaceToken
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
		view.wantsLayer = true
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		configureContentPanes()
		updateDisplayedContent()
	}

	func render(
		document: DocumentIdentifier?,
		detail: DocumentDetailPresentation?,
		tab: ReaderTab,
		searchTerms: [String]
	) {
		let documentChanged = document != activeDocument
		let tabChanged = tab != activeTab

		activeDocument = document
		activeDetail = detail
		activeTab = tab
		activeSearchTerms = searchTerms

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
		if tabChanged, !documentChanged, renderMode == .interactive {
			let dissolve = CATransition()
			dissolve.type = .fade
			dissolve.duration = 0.2
			view.layer?.add(dissolve, forKey: "tabDissolve")
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

	/// The surface whose marks Find Next and Find Previous step through: the shown page or text.
	private var markedSurface: ReaderSearchMarks.Surface? {
		switch shownPane {
		case .pdf: .page
		case .text: .text
		default: nil
		}
	}

	var hasMatches: Bool {
		markedSurface.map { marks.count(on: $0) > 0 } ?? false
	}

	/// Shows the next match, or the previous one for a negative step.
	func showMatch(advancingBy step: Int) {
		markedSurface.map { marks.step(by: step, on: $0) }
	}

	private var searchPlacement: ReaderSearchMarks.Placement? {
		activeDocument.map { ReaderSearchMarks.Placement(document: $0, terms: activeSearchTerms) }
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
		loadedText = nil
		textRefusal = nil
		marks.reset()
		pdfView.document = nil
		renderedPdfView.display(document: nil)
		imageReaderView.display(image: nil)
	}

	private func updateDisplayedContent() {
		guard activeDocument != nil else {
			showPlaceholder(.noDocumentSelected)
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
			showPlaceholder(activeDetail?.originalKind == .unprintedEmail
				? .unprintedEmail(device: device)
				: .originalRefusal(refusal, device: device))
			return
		}
		if originalUnreadable {
			showPlaceholder(.unreadableOriginal)
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
				}
				showOnly(.pdf)
				searchPlacement.map { marks.mark(portableDocument, as: $0) }
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
		showPlaceholder(.loadingOriginal)
	}

	private func displayTextTab() {
		if let refusal = textRefusal {
			showPlaceholder(.textRefusal(refusal))
			return
		}
		guard let text = loadedText, let placement = searchPlacement, loadedTextDocument == activeDocument else {
			showPlaceholder(.loadingText)
			return
		}
		showOnly(.text)
		marks.mark(text, as: placement)
	}
}

private extension DocumentReaderViewController {
	/// Opens a search's match in the Text tab when the original shows nothing to mark, as a scan or
	/// a picture, and the text holds the words. It decides once per document and search, and only
	/// while the original shows, so a person who turns back to the original stays there.
	func showTextForMatchIfNeeded() {
		guard let placement = searchPlacement, !placement.terms.isEmpty, activeTab == .original,
		      tabChosenForMatches != placement
		else {
			return
		}
		let document = placement.document
		if let portableDocument = loadedPortableDocument {
			if marks.pageHoldsMatches(of: placement, in: portableDocument) {
				tabChosenForMatches = placement
				return
			}
		} else if loadedImage == nil, originalRefusal == nil, !originalUnreadable {
			return
		}
		guard loadedTextDocument == document else {
			if requestedTextDocument != document {
				loadText(for: document)
			}
			return
		}
		tabChosenForMatches = placement
		if let text = loadedText, !SearchWordHighlighting.ranges(in: text, terms: activeSearchTerms).isEmpty {
			onShowTextForMatch(document)
		}
	}

	private func showOnly(_ pane: ContentPane) {
		shownPane = pane
		pdfView.isHidden = pane != .pdf
		renderedPdfView.isHidden = pane != .renderedPdf
		imageReaderView.isHidden = pane != .image
		textScrollView.isHidden = pane != .text
		placeholderView.isHidden = pane != .placeholder
	}

	func showPlaceholder(_ presentation: EmptyStatePresentation) {
		placeholderView.render(presentation)
		showOnly(.placeholder)
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
			loadedOriginal = (document, URL(fileURLWithPath: localFile.path))
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
		} catch {
			guard requestNumber == newestOriginalRequest, document == activeDocument else {
				return
			}
			originalRefusal = error
		}
		updateDisplayedContent()
		showTextForMatchIfNeeded()
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
			loadedText = markdown
			textRefusal = nil
		} catch {
			guard requestNumber == newestTextRequest, document == activeDocument else {
				return
			}
			textRefusal = error
		}
		loadedTextDocument = document
		updateDisplayedContent()
		showTextForMatchIfNeeded()
	}
}
