import ApplicationBindings
import LibraryPresentation
import UIKit

/// The details sheet over a document's original: the title and summary, the facts a person copies
/// with a tap, what the document is filed under, its tags, and its file with the ways to the text
/// and to the archive in the browser.
final class DocumentDetailsViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
	private static let copiedDuration = Duration.seconds(1)
	/// The top of the sheet, where the grabber sits, which the list leaves clear.
	private static let grabberClearance: CGFloat = 12
	private static let fadeLength: CGFloat = 16
	/// The sheet has no bar whose scroll edge effect would fade what scrolls up under the grabber, so
	/// the list fades out above the head's place at rest instead of passing under the grabber.
	private let grabberFade: CAGradientLayer = {
		let fade = CAGradientLayer()
		fade.colors = [UIColor.clear, UIColor.black].map(\.cgColor)
		return fade
	}()

	private let showScope: (NamedScope) -> Void
	private let showText: () -> Void
	private(set) var sections: [DocumentDetailSection] = []
	/// The fact that reads "Copied" for a second after its tap.
	private var copiedFact: IndexPath?
	private var copyNumber: UInt64 = 0

	private lazy var collectionView: UICollectionView = {
		let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
			var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
			configuration.backgroundColor = Self.sheetBackground
			if let self, index < sections.count {
				configuration.headerMode = sections[index].header == nil ? .none : .supplementary
				configuration.footerMode = sections[index].footer == nil ? .none : .supplementary
			}
			let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
			// The head and the facts under it read as one block at the medium detent, so the gap
			// between two inset grouped sections stays out between them.
			if index == 0 {
				section.contentInsets.bottom = 0
			} else if index == 1, let self, sections.count > 1, sections[1].header == nil {
				section.contentInsets.top = 8
			}
			return section
		}
		return UICollectionView(frame: .zero, collectionViewLayout: layout)
	}()

	/// Clear from iOS 26, so the sheet's glass shows through, and the grouped background before.
	private static var sheetBackground: UIColor {
		if #available(iOS 26, *) {
			.clear
		} else {
			.systemGroupedBackground
		}
	}

	private lazy var cellRegistration = UICollectionView
		.CellRegistration<UICollectionViewListCell, DocumentDetailRow> { [weak self] cell, indexPath, row in
			row.configure(cell, copied: self?.copiedFact == indexPath)
		}

	private let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
		elementKind: UICollectionView.elementKindSectionHeader
	) { _, _, _ in }

	private let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
		elementKind: UICollectionView.elementKindSectionFooter
	) { _, _, _ in }

	init(showScope: @escaping (NamedScope) -> Void, showText: @escaping () -> Void) {
		self.showScope = showScope
		self.showText = showText
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = Self.sheetBackground
		collectionView.backgroundColor = Self.sheetBackground
		collectionView.frame = view.bounds
		collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		// A registration made during the first dequeue fails an assertion.
		_ = cellRegistration
		collectionView.dataSource = self
		collectionView.delegate = self
		collectionView.accessibilityIdentifier = "document.details"
		view.addSubview(collectionView)
		if #available(iOS 26, *) {
			view.layer.mask = grabberFade
		}
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		guard view.layer.mask === grabberFade, view.bounds.height > 0 else {
			return
		}
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		grabberFade.frame = view.bounds
		grabberFade.startPoint = CGPoint(x: 0.5, y: Self.grabberClearance / view.bounds.height)
		grabberFade.endPoint = CGPoint(x: 0.5, y: (Self.grabberClearance + Self.fadeLength) / view.bounds.height)
		CATransaction.commit()
	}

	func show(_ detail: DocumentDetailPresentation) {
		let shown = DocumentDetailSection.sections(of: detail)
		guard shown != sections else {
			return
		}
		sections = shown
		copiedFact = nil
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
		viewForSupplementaryElementOfKind kind: String,
		at indexPath: IndexPath
	) -> UICollectionReusableView {
		let section = sections[indexPath.section]
		let isFooter = kind == UICollectionView.elementKindSectionFooter
		let view = collectionView.dequeueConfiguredReusableSupplementary(
			using: isFooter ? footerRegistration : headerRegistration,
			for: indexPath
		)
		var content: UIListContentConfiguration = isFooter ? .footer() : .header()
		content.text = isFooter ? section.footer : section.header
		view.contentConfiguration = content
		return view
	}

	func collectionView(_: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
		switch sections[indexPath.section].rows[indexPath.item] {
		case .head, .fileFact: false
		case .fact, .filed, .tag, .extractedText, .openInBrowser: true
		}
	}

	func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		collectionView.deselectItem(at: indexPath, animated: true)
		switch sections[indexPath.section].rows[indexPath.item] {
		case let .fact(row):
			copy(row, at: indexPath)
		case let .filed(_, scope), let .tag(scope):
			showScope(scope)
		case .extractedText:
			showText()
		case let .openInBrowser(page):
			UIApplication.shared.open(page)
		case .head, .fileFact:
			break
		}
	}

	func collectionView(
		_: UICollectionView,
		contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
		point _: CGPoint
	) -> UIContextMenuConfiguration? {
		guard let indexPath = indexPaths.first,
		      let value = sections[indexPath.section].rows[indexPath.item].copyValue
		else {
			return nil
		}
		return UIContextMenuConfiguration(actionProvider: { _ in
			let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
				UIPasteboard.general.string = value
			}
			return UIMenu(children: [copy])
		})
	}

	/// Writes the fact to the pasteboard, and its row reads "Copied" for a second.
	private func copy(_ row: InspectorDetailRow, at indexPath: IndexPath) {
		UIPasteboard.general.string = row.copyValue ?? row.displayValue
		Haptics.factCopied()
		UIAccessibility.post(notification: .announcement, argument: "Copied")
		let previous = copiedFact
		copiedFact = indexPath
		copyNumber &+= 1
		let number = copyNumber
		redraw([previous, indexPath].compactMap(\.self))
		Task { [weak self] in
			try? await Task.sleep(for: Self.copiedDuration)
			guard let self, copyNumber == number else {
				return
			}
			copiedFact = nil
			redraw([indexPath])
		}
	}

	private func redraw(_ indexPaths: [IndexPath]) {
		for indexPath in Set(indexPaths) {
			guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
			      indexPath.section < sections.count, indexPath.item < sections[indexPath.section].rows.count
			else {
				continue
			}
			let row = sections[indexPath.section].rows[indexPath.item]
			UIView.transition(with: cell, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
				row.configure(cell, copied: self.copiedFact == indexPath)
			}
		}
	}
}
