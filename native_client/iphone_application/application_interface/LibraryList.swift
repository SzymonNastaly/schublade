import ApplicationBindings
import LibraryPresentation
import SubmissionQueue
import UIKit

final class LibraryList {
	enum Destination {
		case document(DocumentIdentifier, title: String?)
		/// The form that replaces a token the archive refused.
		case tokenReplacement
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
	private weak var presenter: UIViewController?
	private var dataSource: UICollectionViewDiffableDataSource<LibrarySection, LibraryItem>?
	private var shown: Shown?
	private var arrivals: [UUID: Arrival] = [:]
	private var rows: [DocumentIdentifier: DocumentRow] = [:]
	private var searchText: String?
	private var context = WordingContext.current()
	private var notice: UIContentUnavailableConfiguration?
	private var attention: ConnectionAttention?

	init(
		in view: UIView,
		presenter: UIViewController & UICollectionViewDelegate,
		thumbnails: ThumbnailStore,
		submissions: SubmissionCoordinator
	) {
		self.thumbnails = thumbnails
		self.submissions = submissions
		self.presenter = presenter
		collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewFlowLayout())
		collectionView.collectionViewLayout = layout()
		collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		collectionView.delegate = presenter
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
		arrivals = Dictionary(uniqueKeysWithValues: content.arrivals.map { ($0.id, $0) })
		let previousRows = rows
		rows = Dictionary(content.state.listedSections.flatMap(\.rows).map { ($0.document, $0) }) { first, _ in first }
		var snapshot = Self.snapshot(of: content, noticed: !content.arrivals.isEmpty && notice != nil)
		let previous = dataSource.snapshot()
		// A row shows its date another way under another heading, and marks other words in another
		// search. A snapshot refuses to reconfigure an item it lacks, such as a listed document that
		// an arrival shows.
		let revised = snapshot.itemIdentifiers.filter { item in
			switch item {
			case .arrival, .notice, .attention:
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
			return .document(identifier, title: rows[identifier]?.title)
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
			let title: String? = switch arrival.stage {
			case let .filed(row), let .alreadyHeld(row?): row.title
			default: nil
			}
			return .document(document, title: title)
		case .attention?:
			return attention?.replacesToken == true ? .tokenReplacement : nil
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
			configuration.headerMode = [.listed(nil), .notice, .attention].contains(section) ? .none : .supplementary
			configuration.itemSeparatorHandler = { [weak self] indexPath, separator in
				var aligned = separator
				aligned.bottomSeparatorInsets.leading = DocumentRowContent.textLeading
				if [.notice, .attention].contains(self?.dataSource?.itemIdentifier(for: indexPath)) {
					aligned.topSeparatorVisibility = .hidden
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
		case .listed(nil)?, .notice?, .attention?, nil:
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

/// The swipe actions of an arrival.
private extension LibraryList {
	/// An arrival that the archive has not archived can be removed, and one it did not accept can be
	/// taken elsewhere, because the iPhone still holds its file.
	func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
		guard case let .arrival(identifier)? = dataSource?.itemIdentifier(for: indexPath),
		      let arrival = arrivals[identifier], arrival.document == nil
		else {
			return nil
		}
		var actions: [UIContextualAction] = []
		let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
			self?.submissions.remove(identifier)
			done(true)
		}
		remove.image = UIImage(systemName: "trash")
		actions.append(remove)
		if case .notAccepted = arrival.stage {
			let share = UIContextualAction(style: .normal, title: "Share") { [weak self] _, view, done in
				self?.shareFile(of: identifier, from: view)
				done(true)
			}
			share.image = UIImage(systemName: "square.and.arrow.up")
			share.backgroundColor = .tintColor
			actions.append(share)
		}
		let configuration = UISwipeActionsConfiguration(actions: actions)
		configuration.performsFirstActionWithFullSwipe = false
		return configuration
	}

	/// Hands the file under the name the archive was sent, in a directory of its own that goes once
	/// the sheet closes.
	func shareFile(of identifier: UUID, from view: UIView) {
		guard let entry = submissions.entries.first(where: { $0.id == identifier }),
		      let file = submissions.documentFile(of: entry)
		else {
			return
		}
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
		let copy = directory.appending(path: entry.manifest.fileName)
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			try FileManager.default.copyItem(at: file, to: copy)
		} catch {
			return
		}
		let sheet = UIActivityViewController(activityItems: [copy], applicationActivities: nil)
		sheet.popoverPresentationController?.sourceView = view
		sheet.completionWithItemsHandler = { _, _, _, _ in
			try? FileManager.default.removeItem(at: directory)
		}
		presenter?.present(sheet, animated: true)
	}
}
