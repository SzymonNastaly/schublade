import ApplicationBindings
import LibraryPresentation
import Observation
import ScanRequest
import SubmissionQueue
import UIKit
import VisionKit

/// The screen once an archive is connected: what is on its way to the archive on top, the local
/// copy's documents under their headings below, the search field and the filter menu above, and
/// Scan and Add at the bottom. A restricted token cannot send, so the bottom bar says why instead.
final class LibraryViewController: UIViewController, UICollectionViewDelegate {
	/// What the screen last asked the copy, and what the copy answered.
	private struct ListedAnswer {
		let outcome: LibraryListState.ListingOutcome
		let scope: LibraryScope
		let searchText: String
	}

	/// A person types faster than a listing is worth reading.
	private static let searchPause = Duration.milliseconds(250)

	private let controller: ApplicationController
	private lazy var capture = DocumentCapture(presenter: self, submissions: controller.submissions)
	private lazy var thumbnails = ThumbnailStore(gateway: controller.gateway)
	private(set) lazy var list = LibraryList(
		in: view,
		delegate: self,
		thumbnails: thumbnails,
		submissions: controller.submissions
	)
	private let searchController = UISearchController(searchResultsController: nil)
	private lazy var commands = LibraryCommands(screen: self, capture: capture)

	private var chosenScope = NamedScope(scope: .allDocuments, name: "All Documents")
	private var searchText = ""
	private var answer: ListedAnswer?
	/// What the documents part shows now.
	private(set) var state = LibraryListState.awaitingListing
	private var facets: LibraryFacets?
	/// The content revisions the listing and the facets were last asked at.
	private var listedRevision: UInt64?
	private var facetsRevision: UInt64?
	private var newestListingRequest: UInt64 = 0
	private var searchDelay: Task<Void, Never>?
	/// When a pull asked the copy to read the archive, until the copy answers.
	private var refreshStartedAt: Date?

	init(controller: ApplicationController) {
		self.controller = controller
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		title = "Schublade"
		navigationItem.largeTitleDisplayMode = .always
		navigationItem.backButtonDisplayMode = .minimal
		navigationController?.navigationBar.prefersLargeTitles = true
		view.backgroundColor = .systemBackground
		definesPresentationContext = true
		searchController.obscuresBackgroundDuringPresentation = false
		searchController.searchResultsUpdater = commands
		searchController.delegate = commands
		searchController.searchBar.placeholder = "Search Documents"
		navigationItem.searchController = searchController
		list.refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
		showScope()
		follow()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		navigationController?.setToolbarHidden(searchController.isActive, animated: animated)
		list.deselectAll(animated: animated)
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		answerScanRequest()
	}

	/// Takes a pending scan request once this screen is in the window, and opens the camera unless it
	/// shows already. A request made while it shows is taken too, so that Save does not open the
	/// camera again. A restricted token cannot send, so its request is dropped. A document read at
	/// the time is left, so the Sending row of the scan is in view once the camera closes.
	func answerScanRequest() {
		guard let navigation = navigationController, navigation.viewIfLoaded?.window != nil,
		      ScanRequestCenter.shared.take(), controller.sendingPermitted,
		      !(navigation.presentedViewController is VNDocumentCameraViewController)
		else {
			return
		}
		navigation.popToRootViewController(animated: false)
		guard let presented = presentedViewController ?? navigation.presentedViewController else {
			capture.scan()
			return
		}
		presented.dismiss(animated: true) { [weak self] in
			self?.capture.scan()
		}
	}

	/// The search field's text changed. A cleared field lists at once; typing waits for a pause.
	func searchTextChanged(_ text: String) {
		guard text != searchText else {
			return
		}
		searchText = text
		searchDelay?.cancel()
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			requestListing()
			return
		}
		searchDelay = Task { [weak self] in
			try? await Task.sleep(for: Self.searchPause)
			guard !Task.isCancelled else {
				return
			}
			self?.requestListing()
		}
	}

	func choose(_ scope: NamedScope) {
		guard scope.scope != chosenScope.scope else {
			return
		}
		chosenScope = scope
		showScope()
		list.scrollToTop()
		requestListing()
	}

	/// Opens the document of a row, or of a submission the archive holds.
	func open(_ document: DocumentIdentifier, title: String?) {
		let page = DocumentPageViewController(
			controller: controller,
			document: document,
			provisionalTitle: title
		) { [weak self] scope in
			self?.navigationController?.popToRootViewController(animated: true)
			self?.choose(scope)
		}
		navigationController?.pushViewController(page, animated: true)
	}

	private var scopePresentation: LibraryScopePresentation {
		LibraryScopePresentation.resolve(
			scope: chosenScope.scope,
			name: chosenScope.name,
			searchText: searchText,
			browseOrder: .documentDate
		)
	}

	/// Shows the chosen scope in the subtitle, or before iOS 26 in place of the title.
	private func showScope() {
		let scopeTitle = scopePresentation.title
		if #available(iOS 26, *) {
			navigationItem.subtitle = scopeTitle
		} else {
			title = chosenScope.scope == .allDocuments ? "Schublade" : scopeTitle
		}
		navigationItem.rightBarButtonItem = commands.filterItem(
			menu: LibraryScopeMenu.menu(facets: facets, chosen: chosenScope.scope) { [weak self] scope in
				self?.choose(scope)
			},
			filtering: chosenScope.scope != .allDocuments
		)
	}

	private func follow() {
		withObservationTracking {
			render(
				situation: controller.situation,
				entries: controller.submissions.entries,
				progress: controller.submissions.progress,
				sendingPermitted: controller.sendingPermitted
			)
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.follow()
			}
		}
	}

	private func render(
		situation: ApplicationController.Situation,
		entries: [SubmissionEntry],
		progress: [UUID: Double],
		sendingPermitted: Bool
	) {
		toolbarItems = commands.toolbarItems(sendingPermitted: sendingPermitted)
		guard case let .running(status) = situation else {
			return
		}
		thumbnails.contentRevisionChanged(to: status.contentRevision)
		if status.contentRevision != listedRevision {
			requestListing()
		}
		if status.contentRevision != facetsRevision {
			requestFacets(revision: status.contentRevision)
		}
		endRefreshing(after: status)
		state = answer.map { answer in
			LibraryListState.resolve(
				outcome: answer.outcome,
				status: status,
				scope: answer.scope,
				searchText: answer.searchText,
				context: .current()
			)
		} ?? .awaitingListing
		let searching = !(answer?.searchText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let unavailable = unavailableConfiguration(state, sendingPermitted: sendingPermitted, searching: searching)
		list.show(
			state,
			entries: searching ? [] : entries,
			progress: progress,
			notice: unavailable,
			context: .current()
		)
		contentUnavailableConfiguration = list.isEmpty ? unavailable : nil
	}

	private func rerender() {
		render(
			situation: controller.situation,
			entries: controller.submissions.entries,
			progress: controller.submissions.progress,
			sendingPermitted: controller.sendingPermitted
		)
	}

	/// Reads the listing of the chosen scope and search, and drops an answer that a newer request
	/// overtook.
	private func requestListing() {
		guard case let .running(status) = controller.situation else {
			return
		}
		newestListingRequest &+= 1
		let number = newestListingRequest
		listedRevision = status.contentRevision
		let scope = chosenScope.scope
		let text = searchText
		let request = scopePresentation.request
		Task {
			let outcome: LibraryListState.ListingOutcome
			do throws(ApplicationFault) {
				let listing = try await controller.gateway.listDocuments(request: request)
				outcome = await .listed(Self.rows(of: listing))
			} catch {
				outcome = .failed(error)
			}
			guard number == newestListingRequest else {
				return
			}
			if case .failed(.Stopped) = outcome {
				return
			}
			answer = ListedAnswer(outcome: outcome, scope: scope, searchText: text)
			rerender()
		}
	}

	func collectionView(_: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
		list.destination(at: indexPath) != nil
	}

	func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		guard let destination = list.destination(at: indexPath) else {
			return
		}
		open(destination.document, title: destination.title)
	}
}

private extension LibraryViewController {
	/// Every row at once, because a diffable list needs every identifier. Five thousand rows cross
	/// from Rust in a few milliseconds, away from the main actor.
	@concurrent
	static func rows(of listing: DocumentListing) async -> [ListingRow] {
		listing.rows(first: 0, count: listing.rowCount())
	}

	func requestFacets(revision: UInt64) {
		facetsRevision = revision
		Task {
			guard let answer = try? await controller.gateway.facets(), facetsRevision == revision else {
				return
			}
			facets = answer
			showScope()
		}
	}

	func refresh() {
		refreshStartedAt = .now
		controller.gateway.synchronize()
		Task { [weak self] in
			try? await Task.sleep(for: .seconds(10))
			self?.list.refreshControl.endRefreshing()
			self?.refreshStartedAt = nil
		}
	}

	/// A pull ends once the copy read the archive after it, or found it out of reach.
	func endRefreshing(after status: LibraryStatus) {
		guard let started = refreshStartedAt else {
			return
		}
		let answered = switch (status.copy, status.archive) {
		case let (.complete(synchronizedAt), _):
			synchronizedAt >= started
		case (_, .configured(_, _, .unreachable, _, _)), (_, .configured(_, _, .suspended, _, _)):
			true
		default:
			false
		}
		if answered {
			refreshStartedAt = nil
			list.refreshControl.endRefreshing()
		}
	}

	func unavailableConfiguration(
		_ state: LibraryListState,
		sendingPermitted: Bool,
		searching: Bool
	) -> UIContentUnavailableConfiguration? {
		switch state {
		case .documents:
			return nil
		case .awaitingListing:
			return .loading()
		case let .fillingCopy(status):
			var loading = UIContentUnavailableConfiguration.loading()
			loading.text = "Loading Documents…"
			loading.secondaryText = status.text
			return loading
		case let .empty(empty), let .failed(empty):
			var configuration = UIContentUnavailableConfiguration.search()
			if case .failed = state {
				configuration = .empty()
				configuration.image = UIImage(systemName: "exclamationmark.triangle")
			} else if !searching {
				configuration = .empty()
				configuration.image = UIImage(systemName: "tray")
			}
			configuration.text = empty.title
			configuration.secondaryText = empty.detail
			if empty.showsSearchAllDocumentsButton {
				configuration.button = .plain()
				configuration.button.title = "Search All Documents"
				configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in
					self?.choose(NamedScope(scope: .allDocuments, name: "All Documents"))
				}
			}
			return configuration
		case .emptyArchive:
			var configuration = UIContentUnavailableConfiguration.empty()
			configuration.image = UIImage(systemName: "tray")
			configuration.text = "No Documents Yet"
			configuration.secondaryText = sendingPermitted
				? "Scan a letter, or add a PDF or photo. Schublade sends it to your archive, which reads and files it."
				: "Documents added to your archive in the browser appear here."
			if sendingPermitted {
				configuration.button = .filled()
				configuration.button.title = "Scan"
				configuration.button.image = UIImage(systemName: "doc.viewfinder")
				configuration.button.imagePadding = 8
				configuration.button.cornerStyle = .capsule
				configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.capture.scan() }
			}
			return configuration
		}
	}
}
