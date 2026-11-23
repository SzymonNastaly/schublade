import ApplicationBindings
import LibraryPresentation
import Observation
import UIKit

/// It reads the detail again whenever the copy changes, so a document opened from a Sending row
/// appears once the copy holds it.
final class DocumentPageViewController: UIViewController {
	enum Segment: Equatable {
		case reader(ReaderTab)
		case details

		static let all: [Segment] = [.reader(.original), .reader(.text), .details]

		var title: String {
			switch self {
			case .reader(.original): "Original"
			case .reader(.text): "Text"
			case .details: "Details"
			}
		}
	}

	enum DetailState: Equatable {
		case loading
		/// The archive holds the document, but the copy does not yet.
		case absent
		case loaded(DocumentDetail)
		case failed(ApplicationFault)
	}

	let document: DocumentIdentifier
	private let controller: ApplicationController
	private let showScope: (NamedScope) -> Void
	private lazy var actions = DocumentFileActions(gateway: controller.gateway, document: document, presenter: self)
	private let segmentedControl = UISegmentedControl(items: Segment.all.map(\.title))
	private let segmentBar = UIView()
	private let content = UIView()
	private(set) var detailState = DetailState.loading
	private(set) var segment = Segment.reader(.original)
	private var loadedRevision: UInt64?
	private var newestDetailRequest: UInt64 = 0
	private(set) var original: DocumentOriginalViewController?
	private(set) var text: DocumentTextViewController?
	private(set) var details: DocumentDetailsViewController?

	init(
		controller: ApplicationController,
		document: DocumentIdentifier,
		provisionalTitle: String?,
		showScope: @escaping (NamedScope) -> Void
	) {
		self.controller = controller
		self.document = document
		self.showScope = showScope
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
		buildSegmentBar()
		content.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(content)
		NSLayoutConstraint.activate([
			content.topAnchor.constraint(equalTo: segmentBar.bottomAnchor),
			content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])
		toolbarItems = actions.toolbarItems
		follow()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		navigationController?.setToolbarHidden(false, animated: animated)
	}

	func select(_ segment: Segment) {
		self.segment = segment
		segmentedControl.selectedSegmentIndex = Segment.all.firstIndex(of: segment) ?? 0
		showContent()
	}

	private func buildSegmentBar() {
		segmentedControl.selectedSegmentIndex = 0
		segmentedControl.addAction(UIAction { [weak self] _ in
			guard let self else {
				return
			}
			select(Segment.all[segmentedControl.selectedSegmentIndex])
		}, for: .valueChanged)
		segmentedControl.accessibilityIdentifier = "document.segments"
		segmentedControl.translatesAutoresizingMaskIntoConstraints = false
		segmentBar.translatesAutoresizingMaskIntoConstraints = false
		segmentBar.addSubview(segmentedControl)
		view.addSubview(segmentBar)
		NSLayoutConstraint.activate([
			segmentBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			segmentBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			segmentBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			segmentedControl.topAnchor.constraint(equalTo: segmentBar.topAnchor, constant: 8),
			segmentedControl.bottomAnchor.constraint(equalTo: segmentBar.bottomAnchor, constant: -8),
			segmentedControl.leadingAnchor.constraint(equalTo: segmentBar.layoutMarginsGuide.leadingAnchor),
			segmentedControl.trailingAnchor.constraint(equalTo: segmentBar.layoutMarginsGuide.trailingAnchor),
		])
	}

	private func follow() {
		withObservationTracking {
			if case let .running(status) = controller.situation, status.contentRevision != loadedRevision {
				loadDetail(revision: status.contentRevision)
			}
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.follow()
			}
		}
	}

	private func loadDetail(revision: UInt64) {
		loadedRevision = revision
		newestDetailRequest &+= 1
		let request = newestDetailRequest
		Task {
			let state: DetailState
			do throws(ApplicationFault) {
				state = try await controller.gateway.document(document).map(DetailState.loaded) ?? .absent
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
			segmentBar.isHidden = true
			actions.detail = nil
			contentUnavailableConfiguration = Self.unavailableConfiguration(state)
			return
		}
		let presentation = DocumentDetailPresentation.from(detail, context: .current())
		title = presentation.title
		if #available(iOS 26, *) {
			navigationItem.subtitle = presentation.headerSubtitle
		}
		segmentBar.isHidden = false
		contentUnavailableConfiguration = nil
		actions.detail = presentation
		details?.show(presentation)
		showContent()
	}

	private func showContent() {
		guard case let .loaded(detail) = detailState else {
			return
		}
		// The bar above a part takes the part's background, so no band of another colour divides them.
		view.backgroundColor = segment == .details ? .systemGroupedBackground : .systemBackground
		let presentation = DocumentDetailPresentation.from(detail, context: .current())
		let part: UIViewController
		switch segment {
		case .reader(.original):
			part = original ?? DocumentOriginalViewController(
				gateway: controller.gateway,
				document: document,
				kind: detail.originalKind
			)
			original = part as? DocumentOriginalViewController
		case .reader(.text):
			part = text ?? DocumentTextViewController(gateway: controller.gateway, document: document, searchText: nil)
			text = part as? DocumentTextViewController
		case .details:
			let shown = details ?? DocumentDetailsViewController(showScope: showScope)
			shown.show(presentation)
			details = shown
			part = shown
		}
		for child in children where child !== part {
			child.willMove(toParent: nil)
			child.view.removeFromSuperview()
			child.removeFromParent()
		}
		guard part.parent == nil else {
			return
		}
		addChild(part)
		part.view.frame = content.bounds
		part.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		content.addSubview(part.view)
		part.didMove(toParent: self)
	}

	private static func unavailableConfiguration(_ state: DetailState) -> UIContentUnavailableConfiguration? {
		switch state {
		case .loading:
			return .loading()
		case .absent:
			var configuration = UIContentUnavailableConfiguration.loading()
			configuration.text = "Arriving in Your Library"
			configuration.secondaryText = "The archive holds this document. It opens here once \(IphoneDevice.wording.phrase) "
				+ "has read it."
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
