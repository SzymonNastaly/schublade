import ApplicationBindings
import LibraryPresentation
import Observation
import UIKit

/// Settings, a sheet over the library: the connected archive with the way to a new token, the room
/// downloaded originals take, the ways to scan without opening Schublade while the token can send,
/// and the version.
final class SettingsViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
	private let controller: ApplicationController
	private var sections: [SettingsSection] = []
	private var storage: OriginalStorage?

	private lazy var collectionView: UICollectionView = {
		let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
			var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
			if let self, index < sections.count {
				configuration.headerMode = sections[index].header == nil ? .none : .supplementary
				configuration.footerMode = sections[index].footer == nil ? .none : .supplementary
			}
			return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
		}
		return UICollectionView(frame: .zero, collectionViewLayout: layout)
	}()

	private lazy var cellRegistration = UICollectionView
		.CellRegistration<UICollectionViewListCell, SettingsRow> { [weak self] cell, _, row in
			row.configure(cell) { limit in
				self?.chooseLimit(limit)
			}
		}

	private let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
		elementKind: UICollectionView.elementKindSectionHeader
	) { _, _, _ in }

	private let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
		elementKind: UICollectionView.elementKindSectionFooter
	) { _, _, _ in }

	private let aboutRegistration = UICollectionView.SupplementaryRegistration<SettingsAboutView>(
		elementKind: UICollectionView.elementKindSectionFooter
	) { _, _, _ in }

	/// Settings in a sheet of its own, opened on the replace form when a refused token sent the person
	/// here, which closes the whole sheet once the archive accepts a new one.
	static func sheet(controller: ApplicationController, replacingToken: Bool) -> UINavigationController {
		let settings = SettingsViewController(controller: controller)
		let navigation = UINavigationController(rootViewController: settings)
		if replacingToken, let form = settings.replaceForm(closingSheet: true) {
			navigation.viewControllers = [settings, form]
		}
		navigation.sheetPresentationController?.detents = [.large()]
		return navigation
	}

	private init(controller: ApplicationController) {
		self.controller = controller
		super.init(nibName: nil, bundle: nil)
		title = "Settings"
		navigationItem.largeTitleDisplayMode = .never
		navigationItem.rightBarButtonItem = UIBarButtonItem(
			systemItem: .done,
			primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
		)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .systemGroupedBackground
		collectionView.frame = view.bounds
		collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		collectionView.accessibilityIdentifier = "settings"
		// A registration made during the first dequeue fails an assertion.
		_ = cellRegistration
		collectionView.dataSource = self
		collectionView.delegate = self
		view.addSubview(collectionView)
		follow()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		readStorage()
	}

	/// Shows the newest status of the archive, and again on the next change.
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
		guard case let .running(status) = controller.situation else {
			return
		}
		let shown = SettingsSection.sections(
			of: status,
			limit: controller.environment.preferences.originalStorageLimit,
			storage: storage,
			context: .current()
		)
		guard shown != sections else {
			return
		}
		let previous = sections
		sections = shown
		guard isViewLoaded else {
			return
		}
		// Only the rows that changed are drawn again, so the menu of Keep Originals stays open while the
		// status line moves on.
		guard previous.map(\.rows.count) == shown.map(\.rows.count) else {
			collectionView.reloadData()
			return
		}
		var changed: [IndexPath] = []
		for (section, rows) in shown.enumerated() {
			for (item, row) in rows.rows.enumerated() where previous[section].rows[item] != row {
				changed.append(IndexPath(item: item, section: section))
			}
		}
		collectionView.reconfigureItems(at: changed)
		for (section, shownSection) in shown.enumerated() where previous[section].footer != shownSection.footer {
			if let footer = collectionView.supplementaryView(
				forElementKind: UICollectionView.elementKindSectionFooter,
				at: IndexPath(item: 0, section: section)
			) as? UICollectionViewListCell, case let .text(text)? = shownSection.footer {
				footer.contentConfiguration = Self.footerContent(text)
			}
		}
		collectionView.collectionViewLayout.invalidateLayout()
	}

	private func readStorage() {
		Task {
			storage = try? await controller.gateway.originalStorage()
			render()
		}
	}

	private func chooseLimit(_ limit: UInt64?) {
		controller.environment.preferences.originalStorageLimit = limit
		render()
		Task {
			// Each call applies the choice saved when it runs, so quick choices end on the last one.
			try? await controller.gateway
				.setOriginalStorageLimit(controller.environment.preferences.originalStorageLimit)
			readStorage()
		}
	}

	private func removeDownloadedOriginals() {
		Task {
			try? await controller.gateway.removeDownloadedOriginals()
			readStorage()
		}
	}

	/// The replace form with the archive's address filled in. It returns to Settings once the
	/// archive accepts the new token, or closes the sheet when it opened on the form.
	private func replaceForm(closingSheet: Bool) -> WelcomeViewController? {
		guard let origin = controller.archiveOrigin else {
			return nil
		}
		return WelcomeViewController(
			controller: controller,
			purpose: .tokenReplacement(origin: origin)
		) { [weak self] in
			guard let self else {
				return
			}
			if closingSheet {
				dismiss(animated: true)
			} else {
				navigationController?.popToViewController(self, animated: true)
			}
		}
	}

	// MARK: The list

	func numberOfSections(in _: UICollectionView) -> Int {
		sections.count
	}

	func collectionView(_: UICollectionView, numberOfItemsInSection section: Int) -> Int {
		sections[section].rows.count
	}

	func collectionView(
		_ collectionView: UICollectionView,
		cellForItemAt indexPath: IndexPath
	) -> UICollectionViewCell {
		collectionView.dequeueConfiguredReusableCell(
			using: cellRegistration,
			for: indexPath,
			item: sections[indexPath.section].rows[indexPath.item]
		)
	}

	func collectionView(
		_ collectionView: UICollectionView,
		viewForSupplementaryElementOfKind kind: String,
		at indexPath: IndexPath
	) -> UICollectionReusableView {
		let section = sections[indexPath.section]
		if kind == UICollectionView.elementKindSectionHeader {
			let header = collectionView.dequeueConfiguredReusableSupplementary(
				using: headerRegistration,
				for: indexPath
			)
			var content = UIListContentConfiguration.header()
			content.text = section.header
			header.contentConfiguration = content
			return header
		}
		switch section.footer {
		case .about?:
			return collectionView.dequeueConfiguredReusableSupplementary(using: aboutRegistration, for: indexPath)
		case let .text(text)?:
			let footer = collectionView.dequeueConfiguredReusableSupplementary(
				using: footerRegistration,
				for: indexPath
			)
			footer.contentConfiguration = Self.footerContent(text)
			return footer
		case nil:
			return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
		}
	}

	private static func footerContent(_ text: String) -> UIListContentConfiguration {
		var content = UIListContentConfiguration.footer()
		content.text = text
		return content
	}

	func collectionView(_: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
		sections[indexPath.section].rows[indexPath.item].selectable
	}

	func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		collectionView.deselectItem(at: indexPath, animated: true)
		switch sections[indexPath.section].rows[indexPath.item] {
		case let .openArchiveInBrowser(address):
			UIApplication.shared.open(address)
		case .replaceToken:
			if let form = replaceForm(closingSheet: false) {
				navigationController?.pushViewController(form, animated: true)
			}
		case let .removeDownloadedOriginals(available) where available:
			removeDownloadedOriginals()
		case .archive, .keepOriginals, .removeDownloadedOriginals, .scanShortcut:
			break
		}
	}
}
