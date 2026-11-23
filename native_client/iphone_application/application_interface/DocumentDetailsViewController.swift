import ApplicationBindings
import LibraryPresentation
import UIKit

final class DocumentDetailsViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
	private struct DetailSection {
		let header: String?
		let rows: [DetailRow]
	}

	private struct DetailRow {
		let text: String
		let secondaryText: String?
		let style: DetailRowStyle
		let copyValue: String
		let scope: NamedScope?
	}

	private let showScope: (NamedScope) -> Void
	private var sections: [DetailSection] = []
	private lazy var collectionView: UICollectionView = {
		var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
		configuration.headerMode = .supplementary
		configuration.itemSeparatorHandler = { _, separator in
			var aligned = separator
			aligned.bottomSeparatorInsets.leading = 20
			return aligned
		}
		let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
			var section = configuration
			section.headerMode = self?.sections[index].header == nil ? .none : .supplementary
			return NSCollectionLayoutSection.list(using: section, layoutEnvironment: environment)
		}
		return UICollectionView(frame: .zero, collectionViewLayout: layout)
	}()

	private let cellRegistration = UICollectionView
		.CellRegistration<UICollectionViewListCell, DetailRow> { cell, _, row in
			var content: UIListContentConfiguration
			switch row.style {
			case .title:
				content = .subtitleCell()
				content.textProperties.font = .preferredFont(forTextStyle: .title2).bold()
				content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
				content.secondaryTextProperties.color = .secondaryLabel
				content.textToSecondaryTextVerticalPadding = 6
			case .field:
				content = .valueCell()
				content.prefersSideBySideTextAndSecondaryText = true
				content.secondaryTextProperties.color = row.scope == nil ? .secondaryLabel : InterfacePalette.link
			case .paragraph:
				content = .cell()
			}
			content.text = row.text
			content.secondaryText = row.secondaryText
			cell.contentConfiguration = content
			cell.accessories = row.scope == nil ? [] : [.disclosureIndicator()]
		}

	private let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
		elementKind: UICollectionView.elementKindSectionHeader
	) { _, _, _ in }

	init(showScope: @escaping (NamedScope) -> Void) {
		self.showScope = showScope
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		collectionView.frame = view.bounds
		collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		collectionView.dataSource = self
		collectionView.delegate = self
		collectionView.accessibilityIdentifier = "document.details"
		view.addSubview(collectionView)
	}

	func show(_ detail: DocumentDetailPresentation) {
		let heading = DetailRow(
			text: detail.title,
			secondaryText: detail.headerSubtitle.isEmpty ? nil : detail.headerSubtitle,
			style: .title,
			copyValue: detail.title,
			scope: nil
		)
		var shown = [DetailSection(header: nil, rows: [heading])]
		if !detail.detailRows.isEmpty {
			shown.append(DetailSection(header: "Details", rows: detail.detailRows.map { row in
				DetailRow(
					text: row.label,
					secondaryText: row.displayValue,
					style: .field,
					copyValue: row.copyValue ?? row.displayValue,
					scope: row.linkedScope
				)
			}))
		}
		if let summary = detail.summary {
			shown.append(DetailSection(header: "Summary", rows: [
				DetailRow(text: summary, secondaryText: nil, style: .paragraph, copyValue: summary, scope: nil),
			]))
		}
		if !detail.tags.isEmpty {
			shown.append(DetailSection(header: "Tags", rows: detail.tags.map { tag in
				DetailRow(text: tag.name, secondaryText: nil, style: .paragraph, copyValue: tag.name, scope: tag)
			}))
		}
		shown.append(DetailSection(header: "File", rows: detail.fileFacts.map { fact in
			DetailRow(text: fact.label, secondaryText: fact.value, style: .field, copyValue: fact.value, scope: nil)
		}))
		sections = shown
		if isViewLoaded {
			collectionView.reloadData()
		}
	}

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
		viewForSupplementaryElementOfKind _: String,
		at indexPath: IndexPath
	) -> UICollectionReusableView {
		let header = collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
		var content = UIListContentConfiguration.header()
		content.text = sections[indexPath.section].header
		header.contentConfiguration = content
		return header
	}

	func collectionView(_: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
		sections[indexPath.section].rows[indexPath.item].scope != nil
	}

	func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		collectionView.deselectItem(at: indexPath, animated: true)
		if let scope = sections[indexPath.section].rows[indexPath.item].scope {
			showScope(scope)
		}
	}

	func collectionView(
		_: UICollectionView,
		contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
		point _: CGPoint
	) -> UIContextMenuConfiguration? {
		guard let indexPath = indexPaths.first else {
			return nil
		}
		let value = sections[indexPath.section].rows[indexPath.item].copyValue
		return UIContextMenuConfiguration(actionProvider: { _ in
			let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
				UIPasteboard.general.string = value
			}
			return UIMenu(children: [copy])
		})
	}
}

private enum DetailRowStyle {
	case title
	case field
	case paragraph
}

private extension UIFont {
	func bold() -> UIFont {
		fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? self
	}
}
