import ApplicationBindings
import LibraryPresentation
import Observation
import UIKit

/// How a person reached a document's page, which decides what the page says while the copy lacks
/// the document.
enum DocumentOpening: Equatable {
	/// From a row of the copy's listing, which held the document.
	case listed
	/// From an arrival the archive named, which the copy may not have read yet.
	case arrival
	/// From a row under Matches in Text: the text opens above the page, finding the search's words.
	case textMatch(searchText: String)
}

/// The original under both bars, with the details as a sheet over it and the text one page further.
/// It reads the detail again whenever the copy changes, so a document opened from an arrival
/// appears once the copy holds it, and an email's PDF once the archive printed it.
final class DocumentPageViewController: UIViewController {
	enum DetailState: Equatable {
		case loading
		/// The archive named the document, and the copy has not read it yet.
		case arriving
		/// The copy held the document and holds it no longer, or read the archive without finding it.
		case absent
		case loaded(DocumentDetail)
		case failed(ApplicationFault)
	}

	/// The longest a request for a page of changes takes. A page the copy applied this long after a
	/// page began awaiting a document was requested after the archive named it.
	private static let pageRequestLimit: TimeInterval = 30

	let document: DocumentIdentifier
	private let opening: DocumentOpening
	private let controller: ApplicationController
	private let showScope: (NamedScope) -> Void
	/// When the page began awaiting a document the copy has not read, nil once the copy held it or
	/// when the page opened from the copy's listing.
	private var awaitingSince: Date?
	private(set) var detailState = DetailState.loading
	private var loadedRevision: UInt64?
	private var newestDetailRequest: UInt64 = 0
	private(set) var original: DocumentOriginalViewController?
	private(set) weak var text: DocumentTextViewController?
	private lazy var actions: DocumentFileActions = .init(
		gateway: controller.gateway,
		document: document,
		page: self
	) { [weak self] in
		self?.detailsSheet.toggle()
	}

	private lazy var detailsSheet: DocumentDetailsSheet = .init(
		details: DocumentDetailsViewController(
			showScope: { [weak self] scope in
				self?.detailsSheet.dismiss(animated: true) { self?.showScope(scope) }
			},
			showText: { [weak self] in self?.showText() }
		),
		toolbarItems: actions.sheetItems,
		page: self,
		preferences: controller.environment.preferences
	) { [weak self] covered in
		self?.original?.additionalSafeAreaInsets.bottom = covered
	}

	var details: DocumentDetailsViewController {
		detailsSheet.details
	}

	init(
		controller: ApplicationController,
		document: DocumentIdentifier,
		provisionalTitle: String?,
		opening: DocumentOpening,
		showScope: @escaping (NamedScope) -> Void
	) {
		self.controller = controller
		self.document = document
		self.opening = opening
		self.showScope = showScope
		awaitingSince = opening == .arrival ? Date() : nil
		super.init(nibName: nil, bundle: nil)
		title = provisionalTitle
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		navigationItem.largeTitleDisplayMode = .never
		view.backgroundColor = .systemBackground
		toolbarItems = actions.pageItems
		follow()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		navigationController?.setToolbarHidden(false, animated: animated)
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		presentRememberedDetails(animated: animated)
	}

	/// The sheet goes with the page, by the same gesture. A back swipe the person cancels brings
	/// `viewDidAppear` again, which presents it again.
	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		detailsSheet.dismiss(animated: animated)
	}

	/// Pushes the page, with the text above it when a search matched the text.
	func push(onto navigationController: UINavigationController?) {
		guard let navigationController else {
			return
		}
		guard case let .textMatch(searchText) = opening else {
			navigationController.pushViewController(self, animated: true)
			return
		}
		let stack = navigationController.viewControllers + [self, makeTextPage(searchText: searchText)]
		navigationController.setViewControllers(stack, animated: true)
	}

	/// The text page of this document, for the navigation stack. `searchText` opens it with the
	/// find navigator on those words.
	func makeTextPage(searchText: String?) -> DocumentTextViewController {
		let page = DocumentTextViewController(gateway: controller.gateway, document: document, searchText: searchText)
		text = page
		return page
	}

	/// Pushes the text, after the sheet has gone, which comes back as it was when the person returns.
	func showText() {
		let push = { [weak self] in
			guard let self else {
				return
			}
			navigationController?.pushViewController(makeTextPage(searchText: nil), animated: true)
		}
		detailsSheet.dismiss(animated: true, completion: push)
	}

	private func presentRememberedDetails(animated: Bool) {
		guard detailsSheet.remembered, case .loaded = detailState, view.window != nil,
		      navigationController?.topViewController === self
		else {
			return
		}
		detailsSheet.present(animated: animated)
	}

	private func follow() {
		withObservationTracking {
			guard case let .running(status) = controller.situation else {
				return
			}
			// A copy that read the archive through changes no content when it lacks the document.
			if status.contentRevision != loadedRevision || (detailState == .arriving && copyHasReadArchive(status)) {
				loadDetail(revision: status.contentRevision)
			}
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.follow()
			}
		}
	}

	private func copyHasReadArchive(_ status: LibraryStatus) -> Bool {
		guard let awaitingSince else {
			return true
		}
		return status.copy.hasRead(since: awaitingSince.addingTimeInterval(Self.pageRequestLimit))
	}

	private func loadDetail(revision: UInt64) {
		loadedRevision = revision
		newestDetailRequest &+= 1
		let request = newestDetailRequest
		Task {
			let state: DetailState
			do throws(ApplicationFault) {
				if let detail = try await controller.gateway.document(document) {
					state = .loaded(detail)
				} else if case let .running(status) = controller.situation, !copyHasReadArchive(status) {
					state = .arriving
				} else {
					state = .absent
				}
			} catch {
				state = .failed(error)
			}
			guard request == newestDetailRequest else {
				return
			}
			show(state)
			original?.contentRevisionChanged()
			text?.contentRevisionChanged()
		}
	}

	private func show(_ state: DetailState) {
		detailState = state
		guard case let .loaded(detail) = state else {
			actions.detail = nil
			detailsSheet.dismiss(animated: true)
			removeOriginal()
			view.backgroundColor = .systemBackground
			contentUnavailableConfiguration = Self.unavailableConfiguration(state)
			return
		}
		awaitingSince = nil
		let presentation = DocumentDetailPresentation.from(detail, context: .current())
		title = presentation.title
		if #available(iOS 26, *) {
			// The page count is left out, because it truncated the line.
			navigationItem.subtitle = DocumentDetailPresentation.senderAndDate(of: detail, context: .current())
		}
		contentUnavailableConfiguration = nil
		view.backgroundColor = InterfacePalette.readerBackdrop
		actions.detail = presentation
		details.show(presentation)
		showOriginal(detail)
		presentRememberedDetails(animated: true)
	}

	private func showOriginal(_ detail: DocumentDetail) {
		let failedDocumentPage: URL? = if case .failed = detail.condition {
			URL(string: detail.archivePage)
		} else {
			nil
		}
		if let original {
			original.show(kind: detail.originalKind, failedDocumentPage: failedDocumentPage)
			return
		}
		let shown = DocumentOriginalViewController(
			gateway: controller.gateway,
			document: document,
			kind: detail.originalKind
		)
		shown.show(kind: detail.originalKind, failedDocumentPage: failedDocumentPage)
		addChild(shown)
		shown.view.frame = view.bounds
		shown.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		view.addSubview(shown.view)
		shown.didMove(toParent: self)
		shown.offerText { [weak self] in self?.showText() }
		original = shown
	}

	private func removeOriginal() {
		guard let original else {
			return
		}
		original.willMove(toParent: nil)
		original.view.removeFromSuperview()
		original.removeFromParent()
		self.original = nil
	}

	private static func unavailableConfiguration(_ state: DetailState) -> UIContentUnavailableConfiguration? {
		switch state {
		case .loading:
			return .loading()
		case .arriving:
			var configuration = UIContentUnavailableConfiguration.loading()
			configuration.text = "Arriving in Your Library"
			configuration.secondaryText = "The archive holds this document. It opens here once \(IphoneDevice.wording.phrase) "
				+ "has read it."
			return configuration
		case .absent:
			var configuration = UIContentUnavailableConfiguration.empty()
			configuration.image = UIImage(systemName: "doc")
			configuration.text = "Not in Your Library"
			configuration.secondaryText = "The archive no longer holds this document, or the token of "
				+ "\(IphoneDevice.wording.phrase) may not read it."
			return configuration
		case let .failed(fault):
			var configuration = UIContentUnavailableConfiguration.empty()
			configuration.image = UIImage(systemName: "exclamationmark.triangle")
			configuration.text = "Document Unavailable"
			configuration.secondaryText = LibraryFailureWording.faultSentence(fault)
			return configuration
		case .loaded:
			return nil
		}
	}
}
