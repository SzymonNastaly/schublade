import ApplicationBindings
import LibraryPresentation
import Observation
import ScanRequest
import SubmissionQueue
import UIKit
import VisionKit

final class LibraryViewController: UIViewController, UICollectionViewDelegate {
	private struct ListedAnswer {
		let outcome: LibraryListState.ListingOutcome
		let scope: LibraryScope
		let searchText: String
		let documentCount: UInt32
	}

	/// A person types faster than a listing is worth reading.
	private static let searchPause = Duration.milliseconds(250)

	private let controller: ApplicationController
	private lazy var capture = DocumentCapture(presenter: self, submissions: controller.submissions)
	private lazy var thumbnails = ThumbnailStore(gateway: controller.gateway)
	private(set) lazy var list = LibraryList(
		in: view,
		presenter: self,
		thumbnails: thumbnails,
		submissions: controller.submissions
	)
	private let searchController = UISearchController(searchResultsController: nil)
	private lazy var commands = LibraryCommands(screen: self, capture: capture) { [weak self] in
		guard let self else {
			return []
		}
		return LibraryScopeMenu.elements(facets: facets, chosen: chosenScope.scope) { [weak self] scope in
			self?.choose(scope)
		}
	}

	private var chosenScope = NamedScope(scope: .allDocuments, name: "All Documents")
	private var searchText = ""
	private var answer: ListedAnswer?
	private(set) var state = LibraryListState.awaitingListing
	private var facets: LibraryFacets?
	private var listedRevision: UInt64?
	private var facetsRevision: UInt64?
	private var newestListingRequest: UInt64 = 0
	private var searchDelay: Task<Void, Never>?
	private var refreshStartedAt: Date?
	/// Counts the pulls, so the fallback of an earlier pull leaves a later one alone.
	private var refreshNumber: UInt64 = 0
	private var arrivalMoments = ArrivalMoments()
	private var hasAppeared = false

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
		navigationItem.largeTitleDisplayMode = .always
		navigationItem.backButtonDisplayMode = .minimal
		navigationController?.navigationBar.prefersLargeTitles = true
		view.backgroundColor = .systemBackground
		definesPresentationContext = true
		searchController.obscuresBackgroundDuringPresentation = false
		searchController.searchResultsUpdater = commands
		searchController.delegate = commands
		searchController.searchBar.placeholder = "Search"
		navigationItem.searchController = searchController
		searchController.searchBar.autocapitalizationType = .none
		if #available(iOS 26, *) {
			navigationItem.preferredSearchBarPlacement = .integrated
			// The title keeps naming what the search looks through.
			searchController.hidesNavigationBarDuringPresentation = false
		}
		// The bars blur the rows that scroll under them, at the bottom too.
		setContentScrollView(list.collectionView)
		list.refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
		showScope()
		follow()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		if #available(iOS 26, *) {
			navigationController?.setToolbarHidden(false, animated: animated)
		} else {
			navigationController?.setToolbarHidden(searchController.isActive, animated: animated)
		}
		list.deselectAll(animated: animated)
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		// A request that started the application opens the camera without an animation, so the
		// viewfinder is the first thing the person sees.
		answerScanRequest(animated: hasAppeared)
		hasAppeared = true
	}

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

	/// The title names what the list shows, and the filter is marked while that is not everything.
	private func showScope() {
		title = scopePresentation.title
		commands.showFiltering(chosenScope.scope != .allDocuments)
	}

	private func follow() {
		withObservationTracking {
			render()
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.follow()
			}
		}
	}

	private func render() {
		let sendingPermitted = controller.sendingPermitted
		let context = WordingContext.current()
		let searching = !(answer?.searchText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let arrivals = searching ? [] : controller.submissions.arrivals(context: context)
		let landed = arrivalMoments.follow(
			arrivals,
			sceneActive: view.window?.windowScene?.activationState == .foregroundActive
		)
		guard case let .running(status) = controller.situation else {
			renderStarting(arrivals: arrivals, sendingPermitted: sendingPermitted, context: context)
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
				context: context
			)
		} ?? .awaitingListing
		commands.arrange(
			LibraryCommands.Arrangement(sendingPermitted: sendingPermitted, showsFilter: state != .emptyArchive)
		)
		showSubtitle(status: status)
		let unavailable = LibraryEmptyStates.configuration(
			state,
			sendingPermitted: sendingPermitted,
			searching: searching,
			actions: emptyStateActions
		)
		if landed {
			list.scrollToTop()
		}
		list.show(
			LibraryListContent(state: state, arrivals: arrivals, searchText: searching ? answer?.searchText : nil),
			notice: unavailable,
			context: context
		)
		list.showEmpty(list.isEmpty ? unavailable : nil)
	}

	/// The camera opened by a request that started the application shows over this screen while the
	/// core starts, and the row of its scan shows already.
	private func renderStarting(arrivals: [Arrival], sendingPermitted: Bool, context: WordingContext) {
		commands.arrange(LibraryCommands.Arrangement(sendingPermitted: sendingPermitted, showsFilter: false))
		list.show(
			LibraryListContent(state: .awaitingListing, arrivals: arrivals, searchText: nil),
			notice: nil,
			context: context
		)
	}

	private func rerender() {
		render()
	}

	private var emptyStateActions: LibraryEmptyStates.Actions {
		LibraryEmptyStates.Actions(
			scan: { [weak self] in self?.capture.scan(animated: true) },
			searchAllDocuments: { [weak self] in
				self?.choose(NamedScope(scope: .allDocuments, name: "All Documents"))
			},
			readAgain: { [weak self] in self?.requestListing() }
		)
	}

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
			var count: UInt32 = 0
			do throws(ApplicationFault) {
				let listing = try await controller.gateway.listDocuments(request: request)
				count = listing.documentCount()
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
			answer = ListedAnswer(outcome: outcome, scope: scope, searchText: text, documentCount: count)
			rerender()
		}
	}
}

extension LibraryViewController {
	/// Takes a pending scan request once this screen is in the window, and opens the camera unless it
	/// shows already. A request made while it shows is taken too, so that Save does not open the
	/// camera again. A restricted token cannot send, which an alert says. A document read at the
	/// time is left, so the row of the scan is in view once the camera closes.
	func answerScanRequest(animated: Bool = true) {
		guard let navigation = navigationController, navigation.viewIfLoaded?.window != nil,
		      ScanRequestCenter.shared.take(),
		      !(navigation.presentedViewController is VNDocumentCameraViewController)
		else {
			return
		}
		navigation.popToRootViewController(animated: false)
		let answer = { [weak self] in
			guard let self else {
				return
			}
			if controller.sendingPermitted {
				capture.scan(animated: animated)
			} else {
				let alert = UIAlertController(
					title: "This iPhone Cannot Send",
					message: ConnectedArchive.restrictionSentence,
					preferredStyle: .alert
				)
				alert.addAction(UIAlertAction(title: "OK", style: .default))
				present(alert, animated: true)
			}
		}
		guard let presented = presentedViewController ?? navigation.presentedViewController else {
			answer()
			return
		}
		presented.dismiss(animated: true, completion: answer)
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
		}
	}

	/// The pull ends once the copy has read the archive or found it out of reach, and after ten
	/// seconds at the latest.
	func refresh() {
		refreshStartedAt = .now
		refreshNumber &+= 1
		let number = refreshNumber
		controller.gateway.synchronize()
		Task { [weak self] in
			try? await Task.sleep(for: .seconds(10))
			guard let self, refreshNumber == number, refreshStartedAt != nil else {
				return
			}
			list.refreshControl.endRefreshing()
			refreshStartedAt = nil
		}
	}

	/// From iOS 26 the subtitle under the title says what a person should know first.
	func showSubtitle(status: LibraryStatus) {
		guard #available(iOS 26, *) else {
			return
		}
		let subtitle = LibrarySubtitle.resolve(
			status: status,
			searchText: answer?.searchText ?? "",
			documentCount: answer?.documentCount ?? 0,
			context: .current()
		)
		if navigationItem.subtitle != subtitle {
			navigationItem.subtitle = subtitle
		}
	}

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
}
