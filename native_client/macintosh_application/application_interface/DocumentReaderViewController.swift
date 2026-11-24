import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation
import PDFKit

/// The reader: the original or the extracted text from the window's top edge to its bottom, so the
/// page passes under the toolbar's glass, or an empty state in their place. A search's words are
/// marked in whichever the reader shows, and Find Next and Find Previous step through them.
final class DocumentReaderViewController: NSViewController {
	/// How long a document may take to load before the reader says so. Until then the previous
	/// page stays, so a walk through the list does not flash a notice at every step, as on the iPhone.
	private static let loadingNoticeDelay: Duration = .milliseconds(400)

	private enum ContentPane {
		case pdf
		case renderedPdf
		case image
		case text
		case placeholder
	}

	let queries: any LibraryQueries
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
	var activeDocument: DocumentIdentifier?
	private var activeDetail: DocumentDetailPresentation?
	private var activeSearchTerms: [String] = []
	var requestedOriginalKind: OriginalKind?
	var loadedOriginal: (document: DocumentIdentifier, file: URL)?
	var loadedPortableDocument: PDFDocument?
	var loadedImage: NSImage?
	var originalRefusal: RepresentationRefusal?
	var originalUnreadable = false
	var loadedTextDocument: DocumentIdentifier?
	var requestedTextDocument: DocumentIdentifier?
	var loadedText: String?
	var textRefusal: RepresentationRefusal?
	var newestOriginalRequest: UInt64 = 0
	var newestTextRequest: UInt64 = 0
	private var loadingNoticeDue = false
	private var loadingNoticeTimer: Task<Void, Never>?

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
		if documentChanged || tabChanged {
			restartLoadingNoticeTimer()
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
		showTextForMatchIfNeeded()
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
	}

	private func restartLoadingNoticeTimer() {
		loadingNoticeTimer?.cancel()
		loadingNoticeDue = false
		loadingNoticeTimer = Task { [weak self] in
			try? await Task.sleep(for: Self.loadingNoticeDelay)
			guard let self, !Task.isCancelled else {
				return
			}
			loadingNoticeDue = true
			updateDisplayedContent()
		}
	}

	func updateDisplayedContent() {
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
		showLoadingNotice(.loadingOriginal)
	}

	private func displayTextTab() {
		if let refusal = textRefusal {
			showPlaceholder(.textRefusal(refusal))
			return
		}
		guard let text = loadedText, let placement = searchPlacement, loadedTextDocument == activeDocument else {
			showLoadingNotice(.loadingText)
			return
		}
		showOnly(.text)
		marks.mark(text, as: placement)
	}
}

extension DocumentReaderViewController {
	/// Opens a search's match in the Text tab when the original shows nothing to mark, as a scan or
	/// a picture, and the text holds the words. It decides once per document and search, and only
	/// while the original shows, so a person who turns back to the original stays there. The turn is
	/// reported after the render that found it, which it changes.
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
			let reportTurn = onShowTextForMatch
			Task { reportTurn(document) }
		}
	}

	/// Says that the document loads once it took longer than the delay, and until then keeps the
	/// previous document's page or text, or shows nothing in place of a notice about it.
	private func showLoadingNotice(_ presentation: EmptyStatePresentation) {
		if loadingNoticeDue {
			showPlaceholder(presentation)
		} else if shownPane == .placeholder {
			showOnly(nil)
		}
	}

	private func showOnly(_ pane: ContentPane?) {
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
}
