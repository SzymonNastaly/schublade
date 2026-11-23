import ApplicationBindings
import LibraryPresentation
import SubmissionQueue
import UIKit

/// The library screen's collection view: the Sending section and the listing's sections in one
/// diffable list, whose changes animate. It draws what `show` hands it and keeps nothing else.
final class LibraryList {
	/// Where a selected row leads.
	struct Destination {
		let document: DocumentIdentifier
		let title: String?
	}

	let refreshControl = UIRefreshControl()
	let collectionView: UICollectionView
	private let thumbnails: ThumbnailStore
	private let submissions: SubmissionCoordinator
	private var dataSource: UICollectionViewDiffableDataSource<LibrarySection, LibraryItem>?
	private var shownState: LibraryListState?
	private var shownEntries: [SubmissionEntry] = []
	private var shownProgress: [UUID: Double] = [:]
	private var rows: [DocumentIdentifier: DocumentRow] = [:]
	private var context = WordingContext.current()
	private var notice: UIContentUnavailableConfiguration?

	init(
		in view: UIView,
		delegate: UICollectionViewDelegate,
		thumbnails: ThumbnailStore,
		submissions: SubmissionCoordinator
	) {
		self.thumbnails = thumbnails
		self.submissions = submissions
		collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewFlowLayout())
		collectionView.collectionViewLayout = layout()
		collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		collectionView.delegate = delegate
		collectionView.refreshControl = refreshControl
		collectionView.accessibilityIdentifier = "library.list"
		view.addSubview(collectionView)
		dataSource = makeDataSource()
	}

	/// Whether the list holds no row, so a message takes its place.
	var isEmpty: Bool {
		(dataSource?.snapshot().numberOfItems ?? 0) == 0
	}

	func show(
		_ state: LibraryListState,
		entries: [SubmissionEntry],
		progress: [UUID: Double],
		notice: UIContentUnavailableConfiguration?,
		context: WordingContext
	) {
		guard let dataSource, state != shownState || entries != shownEntries || progress != shownProgress else {
			return
		}
		self.context = context
		self.notice = notice
		let previousRows = rows
		shownState = state
		shownEntries = entries
		shownProgress = progress
		var snapshot = NSDiffableDataSourceSnapshot<LibrarySection, LibraryItem>()
		if !entries.isEmpty {
			snapshot.appendSections([.sending])
			snapshot.appendItems(entries.map { .submission($0.id) })
		}
		rows = [:]
		if case let .documents(sections) = state {
			for section in sections {
				snapshot.appendSections([.listed(section.heading)])
				snapshot.appendItems(section.rows.map { .document($0.document) })
				for row in section.rows {
					rows[row.document] = row
				}
			}
		}
		// Below what is on its way, the message about the listing takes a row, so it never leaves the
		// rest of the screen empty.
		let noticed = !entries.isEmpty && notice != nil
		if noticed {
			snapshot.appendSections([.notice])
			snapshot.appendItems([.notice])
		}
		let revised = rows.compactMap { identifier, row in
			previousRows[identifier].flatMap { $0 == row ? nil : LibraryItem.document(identifier) }
		}
		snapshot.reconfigureItems(entries.map { .submission($0.id) } + revised + (noticed ? [.notice] : []))
		dataSource.apply(snapshot, animatingDifferences: collectionView.window != nil)
	}

	func destination(at indexPath: IndexPath) -> Destination? {
		switch dataSource?.itemIdentifier(for: indexPath) {
		case let .document(identifier)?:
			return Destination(document: identifier, title: rows[identifier]?.title)
		case let .submission(identifier)?:
			guard case let .archived(document, _, _)? = shownEntries.first(where: { $0.id == identifier })?.answer
			else {
				return nil
			}
			return Destination(document: DocumentIdentifier(value: document), title: nil)
		case .notice?, nil:
			return nil
		}
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

	/// A plain list, as Mail's, with a header for every section that has one.
	private func layout() -> UICollectionViewLayout {
		UICollectionViewCompositionalLayout { [weak self] index, environment in
			var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
			let section = self?.dataSource?.sectionIdentifier(for: index)
			configuration.headerMode = section == .listed(nil) || section == .notice ? .none : .supplementary
			configuration.itemSeparatorHandler = { [weak self] indexPath, separator in
				var aligned = separator
				aligned.bottomSeparatorInsets.leading = DocumentRowContent.textLeading
				if self?.dataSource?.itemIdentifier(for: indexPath) == .notice {
					aligned.bottomSeparatorVisibility = .hidden
				}
				return aligned
			}
			configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
				self?.swipeActions(at: indexPath)
			}
			return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
		}
	}

	private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
		guard case let .submission(identifier)? = dataSource?.itemIdentifier(for: indexPath) else {
			return nil
		}
		let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
			self?.submissions.remove(identifier)
			done(true)
		}
		return UISwipeActionsConfiguration(actions: [remove])
	}

	private func makeDataSource() -> UICollectionViewDiffableDataSource<LibrarySection, LibraryItem> {
		let cell = UICollectionView
			.CellRegistration<UICollectionViewListCell, LibraryItem> { [weak self] cell, _, item in
				self?.configure(cell, item)
			}
		let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
			elementKind: UICollectionView.elementKindSectionHeader
		) { [weak self] header, _, indexPath in
			var content = UIListContentConfiguration.header()
			content.text = self?.headerText(at: indexPath.section)
			header.contentConfiguration = content
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

	private func headerText(at index: Int) -> String? {
		switch dataSource?.sectionIdentifier(for: index) {
		case .sending?:
			"Sending"
		case let .listed(heading?)?:
			DocumentFormatting.headingText(heading, context: context)
		case .listed(nil)?, .notice?, nil:
			nil
		}
	}

	private func configure(_ cell: UICollectionViewListCell, _ item: LibraryItem) {
		switch item {
		case let .submission(identifier):
			guard let entry = shownEntries.first(where: { $0.id == identifier }) else {
				return
			}
			LibraryRowConfiguration.configure(cell, submission: entry, sentFraction: shownProgress[identifier])
		case let .document(identifier):
			guard let row = rows[identifier] else {
				return
			}
			let picture = thumbnails.picture(for: identifier) { [weak self] loaded in
				self?.pictureLoaded(loaded)
			}
			LibraryRowConfiguration.configure(cell, document: row, picture: picture, context: context)
		case .notice:
			cell.contentConfiguration = notice
			cell.accessories = []
		}
	}

	private func pictureLoaded(_ document: DocumentIdentifier) {
		guard var snapshot = dataSource?.snapshot(), snapshot.indexOfItem(.document(document)) != nil else {
			return
		}
		snapshot.reconfigureItems([.document(document)])
		dataSource?.apply(snapshot, animatingDifferences: false)
	}
}
