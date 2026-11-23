import ApplicationBindings
import LibraryPresentation
import SubmissionQueue
import UIKit

final class LibraryList {
	enum Destination {
		case document(DocumentIdentifier, title: String?, opening: DocumentOpening)
		/// The form that replaces a token the archive refused.
		case tokenReplacement
		/// A scope the search offered.
		case scope(NamedScope)
	}

	/// Everything a snapshot is made of, so an unchanged input applies nothing.
	private struct Shown: Equatable {
		let content: LibraryListContent
		let notice: NoticeWording?
		let now: Date
	}

	/// What a notice says. Its configuration holds actions, which never compare equal.
	private struct NoticeWording: Equatable {
		let text: String?
		let secondaryText: String?
		let buttonTitle: String?

		init(_ notice: UIContentUnavailableConfiguration) {
			text = notice.text
			secondaryText = notice.secondaryText
			buttonTitle = notice.button.title
		}
	}

	let refreshControl = UIRefreshControl()
	let collectionView: UICollectionView
	private let thumbnails: ThumbnailStore
	private let submissions: SubmissionCoordinator
	private let swipeActions: LibrarySwipeActions
	private weak var presenter: UIViewController?
	private var dataSource: UICollectionViewDiffableDataSource<LibrarySection, LibraryItem>?
	private var shown: Shown?
	private var arrivals: [UUID: Arrival] = [:]
	private var rows: [DocumentIdentifier: DocumentRow] = [:]
	private var searchText: String?
	private var context = WordingContext.current()
	private var notice: UIContentUnavailableConfiguration?
	private var attention: ConnectionAttention?
	private var suggestions: [LibraryScope: ScopeSuggestion] = [:]

	init(
		in view: UIView,
		presenter: UIViewController,
		thumbnails: ThumbnailStore,
		submissions: SubmissionCoordinator,
		gateway: ApplicationGateway
	) {
		self.thumbnails = thumbnails
		self.submissions = submissions
		swipeActions = LibrarySwipeActions(gateway: gateway, submissions: submissions, presenter: presenter)
		self.presenter = presenter
		collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewFlowLayout())
		collectionView.collectionViewLayout = layout()
		collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		collectionView.refreshControl = refreshControl
		collectionView.alwaysBounceVertical = true
		collectionView.accessibilityIdentifier = "library.list"
		view.addSubview(collectionView)
		dataSource = makeDataSource()
	}

	var isEmpty: Bool {
		(dataSource?.snapshot().numberOfItems ?? 0) == 0
	}

	/// Shows the documents of the content's state under their headings, with its arrivals and the
	/// listing's documents in ingestion together on top. The listing's own Arriving heading is not
	/// drawn again.
	func show(_ content: LibraryListContent, notice: UIContentUnavailableConfiguration?, context: WordingContext) {
		let next = Shown(
			content: content,
			notice: notice.map(NoticeWording.init),
			now: context.calendar.startOfDay(for: context.now)
		)
		guard let dataSource, next != shown else {
			return
		}
		let searchChanged = shown?.content.searchText != content.searchText
		shown = next
		self.context = context
		self.notice = notice
		searchText = content.searchText
		attention = content.attention
		suggestions = Dictionary(content.suggestions.map { ($0.scope.scope, $0) }) { first, _ in first }
		arrivals = Dictionary(uniqueKeysWithValues: content.arrivals.map { ($0.id, $0) })
		let previousRows = rows
		rows = Dictionary(content.state.listedSections.flatMap(\.rows).map { ($0.document, $0) }) { first, _ in first }
		let shared = !content.arrivals.isEmpty || !content.suggestions.isEmpty
		var snapshot = Self.snapshot(of: content, noticed: shared && notice != nil)
		let previous = dataSource.snapshot()
		// A row shows its date another way under another heading, and marks other words in another
		// search. A snapshot refuses to reconfigure an item it lacks, such as a listed document that
		// an arrival shows.
		let revised = snapshot.itemIdentifiers.filter { item in
			switch item {
			case .arrival, .notice, .attention, .suggestion:
				true
			case let .document(identifier):
				searchChanged || previousRows[identifier] != rows[identifier]
					|| previous.sectionIdentifier(containingItem: item) != snapshot
					.sectionIdentifier(containingItem: item)
			}
		}
		snapshot.reconfigureItems(revised)
		dataSource.apply(snapshot, animatingDifferences: collectionView.window != nil)
	}

	/// The message of an empty list, behind it, so the list can still be pulled to refresh.
	func showEmpty(_ configuration: UIContentUnavailableConfiguration?) {
		guard let configuration else {
			collectionView.backgroundView = nil
			return
		}
		if let shown = collectionView.backgroundView as? UIContentUnavailableView {
			shown.configuration = configuration
		} else {
			collectionView.backgroundView = UIContentUnavailableView(configuration: configuration)
		}
	}

	func destination(at indexPath: IndexPath) -> Destination? {
		switch dataSource?.itemIdentifier(for: indexPath) {
		case let .document(identifier)?:
			let textMatched = dataSource?.sectionIdentifier(for: indexPath.section) == .listed(.textMatched)
			let opening: DocumentOpening = if textMatched, let searchText {
				.textMatch(searchText: searchText)
			} else {
				.listed
			}
			return .document(identifier, title: rows[identifier]?.title, opening: opening)
		case let .arrival(identifier)?:
			guard let arrival = arrivals[identifier] else {
				return nil
			}
			if arrival.stage == .tokenRefused {
				return .tokenReplacement
			}
			guard let document = arrival.document else {
				return nil
			}
			switch arrival.stage {
			case let .filed(row), let .alreadyHeld(row?):
				return .document(document, title: row.title, opening: .listed)
			case .sent, .alreadyHeld(nil):
				return .document(document, title: nil, opening: .arrival)
			default:
				return .document(document, title: nil, opening: .listed)
			}
		case .attention?:
			return attention?.replacesToken == true ? .tokenReplacement : nil
		case let .suggestion(scope)?:
			return suggestions[scope].map { .scope($0.scope) }
		case .notice?, nil:
			return nil
		}
	}

	func item(at indexPath: IndexPath) -> LibraryItem? {
		dataSource?.itemIdentifier(for: indexPath)
	}

	/// The listed row of a document, which a search or a scope may not show.
	func row(of document: DocumentIdentifier) -> DocumentRow? {
		rows[document]
	}

	func indexPath(of item: LibraryItem) -> IndexPath? {
		dataSource?.indexPath(for: item)
	}

	func deselectAll(animated: Bool) {
		for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
			collectionView.deselectItem(at: indexPath, animated: animated)
		}
	}

	func scrollToTop() {
		collectionView.setContentOffset(
			CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
			animated: false
		)
	}
}

private extension LibraryList {
	static func snapshot(
		of content: LibraryListContent,
		noticed: Bool
	) -> NSDiffableDataSourceSnapshot<LibrarySection, LibraryItem> {
		let listed = content.state.listedSections
		let shownByArrival = Set(content.arrivals.compactMap(\.document))
		let arrivingDocuments = listed.filter { $0.heading == .arriving }
			.flatMap { $0.rows.map(\.document) }
			.filter { !shownByArrival.contains($0) }
		var snapshot = NSDiffableDataSourceSnapshot<LibrarySection, LibraryItem>()
		if content.attention != nil {
			snapshot.appendSections([.attention])
			snapshot.appendItems([.attention])
		}
		if !content.suggestions.isEmpty {
			snapshot.appendSections([.suggestions])
			snapshot.appendItems(content.suggestions.map { .suggestion($0.scope.scope) })
		}
		if !content.arrivals.isEmpty || !arrivingDocuments.isEmpty {
			snapshot.appendSections([.arriving])
			snapshot.appendItems(content.arrivals.map { .arrival($0.id) } + arrivingDocuments.map { .document($0) })
		}
		for section in listed where section.heading != .arriving {
			snapshot.appendSections([.listed(section.heading)])
			snapshot.appendItems(section.rows.map { .document($0.document) })
		}
		// Below what is on its way, the message about the listing takes a row, so it never leaves the
		// rest of the screen empty.
		if noticed {
			snapshot.appendSections([.notice])
			snapshot.appendItems([.notice])
		}
		return snapshot
	}

	func layout() -> UICollectionViewLayout {
		UICollectionViewCompositionalLayout { [weak self] index, environment in
			var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
			let section = self?.dataSource?.sectionIdentifier(for: index)
			configuration.headerMode = [.listed(nil), .notice, .attention, .suggestions].contains(section)
				? .none : .supplementary
			configuration.itemSeparatorHandler = { [weak self] indexPath, separator in
				var aligned = separator
				aligned.topSeparatorVisibility = .hidden
				switch self?.dataSource?.itemIdentifier(for: indexPath) {
				case .notice?, .attention?:
					aligned.bottomSeparatorVisibility = .hidden
				case .suggestion?:
					break
				case .arrival?, .document?, nil:
					aligned.bottomSeparatorInsets.leading = DocumentRowContent.textLeading
				}
				return aligned
			}
			configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
				switch self?.dataSource?.itemIdentifier(for: indexPath) {
				case let .document(document)?:
					self?.rows[document].flatMap { self?.swipeActions.configuration(document: $0) }
				case let .arrival(identifier)?:
					self?.arrivals[identifier].flatMap { self?.swipeActions.configuration(arrival: $0) }
				default:
					nil
				}
			}
			return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
		}
	}

	func makeDataSource() -> UICollectionViewDiffableDataSource<LibrarySection, LibraryItem> {
		let cell = UICollectionView
			.CellRegistration<UICollectionViewListCell, LibraryItem> { [weak self] cell, indexPath, item in
				self?.configure(cell, item, at: indexPath)
			}
		let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
			elementKind: UICollectionView.elementKindSectionHeader
		) { [weak self] header, _, indexPath in
			var content = UIListContentConfiguration.header()
			content.text = self?.headerText(at: indexPath.section)
			header.contentConfiguration = content
			// A pinned heading covers the rows that scroll under it.
			var background = UIBackgroundConfiguration.clear()
			background.backgroundColor = .systemBackground
			header.backgroundConfiguration = background
		}
		let source = UICollectionViewDiffableDataSource<LibrarySection, LibraryItem>(
			collectionView: collectionView
		) { view, indexPath, item in
			view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
		}
		source.supplementaryViewProvider = { view, _, indexPath in
			view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
		}
		return source
	}

	func headerText(at index: Int) -> String? {
		switch dataSource?.sectionIdentifier(for: index) {
		case .arriving?:
			"Arriving"
		case let .listed(heading?)?:
			DocumentFormatting.headingText(heading, context: context)
		case .listed(nil)?, .notice?, .attention?, .suggestions?, nil:
			nil
		}
	}

	func configure(_ cell: UICollectionViewListCell, _ item: LibraryItem, at indexPath: IndexPath) {
		switch item {
		case let .arrival(identifier):
			guard let arrival = arrivals[identifier] else {
				return
			}
			// The archive's picture once the copy holds one, else the page this iPhone sent.
			let archived = arrival.document.flatMap { document in
				thumbnails.picture(for: document) { [weak self] loaded in
					self?.pictureLoaded(loaded)
				}
			}
			LibraryRowConfiguration.configure(
				cell,
				arrival: arrival,
				picture: archived ?? submissions.picture(of: identifier),
				context: context
			)
		case let .document(identifier):
			guard let row = rows[identifier] else {
				return
			}
			let picture = thumbnails.picture(for: identifier) { [weak self] loaded in
				self?.pictureLoaded(loaded)
			}
			let setting: DocumentRowSetting = if let searchText {
				.searching(searchText)
			} else if case .listed(.period?)? = dataSource?.sectionIdentifier(for: indexPath.section) {
				.browsing(underMonth: true)
			} else {
				.browsing(underMonth: false)
			}
			LibraryRowConfiguration.configure(cell, document: row, picture: picture, setting: setting, context: context)
		case .notice:
			LibraryRowConfiguration.configure(cell, notice: notice)
		case let .suggestion(scope):
			if let suggestion = suggestions[scope] {
				LibraryRowConfiguration.configure(cell, suggestion: suggestion)
			}
		case .attention:
			if let attention {
				LibraryRowConfiguration.configure(cell, attention: attention)
			}
		}
	}

	func pictureLoaded(_ document: DocumentIdentifier) {
		guard var snapshot = dataSource?.snapshot() else {
			return
		}
		let showing = arrivals.values.filter { $0.document == document }.map { LibraryItem.arrival($0.id) }
			+ [LibraryItem.document(document)]
		let present = showing.filter { snapshot.indexOfItem($0) != nil }
		guard !present.isEmpty else {
			return
		}
		snapshot.reconfigureItems(present)
		dataSource?.apply(snapshot, animatingDifferences: false)
	}
}
