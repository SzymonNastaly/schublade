import ApplicationBindings
import LibraryPresentation
import Observation
import ScanRequest
import SubmissionQueue
import UIKit
import VisionKit

final class LibraryViewController: UIViewController {
	private struct ListedAnswer {
		let outcome: LibraryListState.ListingOutcome
		let scope: LibraryScope
		let searchText: String
		let documentCount: UInt32
	}

	/// A person types faster than a listing is worth reading.
	private static let searchPause = Duration.milliseconds(250)

	let controller: ApplicationController
	private(set) lazy var capture = DocumentCapture(presenter: self, submissions: controller.submissions)
	private lazy var thumbnails = ThumbnailStore(gateway: controller.gateway)
	private(set) lazy var list = LibraryList(
		in: view,
		presenter: self,
		thumbnails: thumbnails,
		submissions: controller.submissions,
		gateway: controller.gateway
	)
	private lazy var interaction = LibraryInteraction(
		screen: self,
		list: list,
		thumbnails: thumbnails,
		gateway: controller.gateway
	)
	private let searchController = UISearchController(searchResultsController: nil)
	private lazy var search = LibrarySearch(screen: self)
	private var refresh: LibraryRefresh?
	private lazy var commands = LibraryCommands(screen: self, capture: capture) { [weak self] in
		guard let self else {
			return []
		}
		return LibraryScopeMenu.elements(facets: facets, chosen: chosenScope.scope) { [weak self] scope in
			self?.choose(scope)
		}
	}

	private(set) var chosenScope = NamedScope.allDocuments
	private var searchText = ""
	private var answer: ListedAnswer?
	private(set) var state = LibraryListState.awaitingListing
	private(set) var facets: LibraryFacets?
	private var listedRevision: UInt64?
	private var facetsRevision: UInt64?
	private var newestListingRequest: UInt64 = 0
	private var searchDelay: Task<Void, Never>?
	private var arrivalMoments = ArrivalMoments()
	private var hasAppeared = false
	private var shownAttention: ConnectionAttention?

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
		list.collectionView.delegate = interaction
		navigationItem.backButtonDisplayMode = .minimal
		navigationController?.navigationBar.prefersLargeTitles = true
		view.backgroundColor = .systemBackground
		definesPresentationContext = true
		searchController.obscuresBackgroundDuringPresentation = false
		searchController.searchResultsUpdater = search
		searchController.delegate = search
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
		refresh = LibraryRefresh(control: list.refreshControl, gateway: controller.gateway) { [weak self] in
			if case let .running(status)? = self?.controller.situation {
				status
			} else {
				nil
			}
		}
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
		guard !text.isBlank else {
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
		search.showToken(in: searchController, scope: chosenScope)
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

	private var emptyStateActions: LibraryEmptyStates.Actions {
		LibraryEmptyStates.Actions(
			scan: { [weak self] in self?.capture.scan(animated: true) },
			searchAllDocuments: { [weak self] in
				self?.choose(.allDocuments)
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
			render()
		}
	}
}

extension LibraryViewController {
	func open(_ document: DocumentIdentifier, title: String?, opening: DocumentOpening) {
		let page = DocumentPageViewController(
			controller: controller,
			document: document,
			provisionalTitle: title,
			opening: opening
		) { [weak self] scope in
			self?.navigationController?.popToRootViewController(animated: true)
			self?.choose(scope)
		}
		page.push(onto: navigationController)
	}

	/// A scope the search offered: the text goes, and the scope becomes the search field's token.
	func chooseSuggested(_ scope: NamedScope) {
		searchController.searchBar.text = ""
		searchTextChanged("")
		choose(scope)
	}

	/// Settings in a sheet, opened on the replace form when the token needs replacing.
	func openSettings(replacingToken: Bool) {
		present(SettingsViewController.sheet(controller: controller, replacingToken: replacingToken), animated: true)
	}

	/// Takes a pending scan request once this screen is in the window, and opens the camera unless it
	/// shows already. A request made while it shows is taken too, so that Save does not open the
	/// camera again. A document read at the time is left, so the row of the scan is in view once the
	/// camera closes.
	func answerScanRequest(animated: Bool = true) {
		guard let navigationController else {
			return
		}
		capture.answerScanRequest(
			in: navigationController,
			sendingPermitted: controller.sendingPermitted,
			animated: animated
		)
	}
}

private extension LibraryViewController {
	func render() {
		let sendingPermitted = controller.sendingPermitted
		let context = WordingContext.current()
		let searching = !(answer?.searchText ?? "").isBlank
		let arrivals = searching ? [] : controller.submissions.arrivals(context: context)
		let landed = arrivalMoments.follow(
			arrivals,
			sceneActive: view.window?.windowScene?.activationState == .foregroundActive
		)
		guard case let .running(status) = controller.situation else {
			renderStarting(arrivals: arrivals, sendingPermitted: sendingPermitted, context: context)
			return
		}
		followCopy(status)
		state = resolvedState(status: status, context: context)
		commands.arrange(
			LibraryCommands.Arrangement(sendingPermitted: sendingPermitted, showsFilter: state != .emptyArchive)
		)
		showSubtitle(status: status)
		let attention = announced(ConnectionAttention.resolve(status.archive))
		let unavailable = LibraryEmptyStates.configuration(
			state,
			sendingPermitted: sendingPermitted,
			searching: searching,
			actions: emptyStateActions
		)
		if landed {
			list.scrollToTop()
		}
		let searchText = searching ? answer?.searchText : nil
		list.show(
			LibraryListContent(
				attention: attention,
				suggestions: searchText.map { LibrarySearch.suggestions(
					for: $0,
					facets: facets,
					chosen: chosenScope.scope
				) }
					?? [],
				state: state,
				arrivals: arrivals,
				searchText: searchText
			),
			notice: unavailable,
			context: context
		)
		list.showEmpty(list.isEmpty ? unavailable : nil)
	}

	/// The camera opened by a request that started the application shows over this screen while the
	/// core starts, and the row of its scan shows already.
	func renderStarting(arrivals: [Arrival], sendingPermitted: Bool, context: WordingContext) {
		commands.arrange(LibraryCommands.Arrangement(sendingPermitted: sendingPermitted, showsFilter: false))
		list.show(
			LibraryListContent(
				attention: nil,
				suggestions: [],
				state: .awaitingListing,
				arrivals: arrivals,
				searchText: nil
			),
			notice: nil,
			context: context
		)
	}

	/// Reads the listing and the facets again when the copy changed, and ends a pull it answered.
	func followCopy(_ status: LibraryStatus) {
		thumbnails.contentRevisionChanged(to: status.contentRevision)
		if status.contentRevision != listedRevision {
			requestListing()
		}
		if status.contentRevision != facetsRevision {
			requestFacets(revision: status.contentRevision)
		}
		refresh?.follow(status)
	}

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

	func resolvedState(status: LibraryStatus, context: WordingContext) -> LibraryListState {
		guard let answer else {
			return .awaitingListing
		}
		return LibraryListState.resolve(
			outcome: answer.outcome,
			status: status,
			scope: answer.scope,
			searchText: answer.searchText,
			context: context
		)
	}

	/// VoiceOver says a connection that newly needs the person.
	func announced(_ attention: ConnectionAttention?) -> ConnectionAttention? {
		if attention != shownAttention, let attention {
			UIAccessibility.post(notification: .announcement, argument: "\(attention.title). \(attention.detail)")
		}
		shownAttention = attention
		return attention
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
}
