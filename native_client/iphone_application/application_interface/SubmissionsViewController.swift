import Observation
import ScanRequest
import SubmissionQueue
import UIKit
import VisionKit

/// The main screen: Scan at the bottom, Add in the navigation bar, and every submission with what
/// the archive answered. A restricted token cannot send, so the screen says why in place of both.
/// A scan requested from outside the application presents the document camera once this screen shows.
final class SubmissionsViewController: UIViewController, UICollectionViewDelegate {
	private let controller: ApplicationController
	private lazy var capture = DocumentCapture(presenter: self, submissions: controller.submissions)
	private var collectionView: UICollectionView?
	private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>?
	private let scanButton = UIButton(configuration: .filled())
	private let restrictionLabel = UILabel()
	private lazy var addItem = UIBarButtonItem(
		title: "Add",
		image: UIImage(systemName: "plus"),
		menu: UIMenu(children: [
			UIAction(title: "Photos", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
				self?.capture.choosePhotos()
			},
			UIAction(title: "Files", image: UIImage(systemName: "folder")) { [weak self] _ in
				self?.capture.chooseFiles()
			},
		])
	)

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
		navigationController?.navigationBar.prefersLargeTitles = true
		view.backgroundColor = .systemGroupedBackground
		buildList()
		buildScanButton()
		buildRestrictionLabel()
		follow()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		answerScanRequest()
	}

	private func buildList() {
		var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
		configuration.headerMode = .supplementary
		configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
			guard let identifier = self?.dataSource?.itemIdentifier(for: indexPath) else {
				return nil
			}
			let remove = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
				self?.controller.submissions.remove(identifier)
				done(true)
			}
			return UISwipeActionsConfiguration(actions: [remove])
		}
		let list = UICollectionView(
			frame: view.bounds,
			collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
		)
		list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		list.contentInset.bottom = 96
		list.delegate = self
		view.addSubview(list)
		collectionView = list

		let cell = UICollectionView
			.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, identifier in
				self?.configure(cell, identifier)
			}
		let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
			elementKind: UICollectionView.elementKindSectionHeader
		) { header, _, _ in
			var content = UIListContentConfiguration.header()
			content.text = "Sending"
			header.contentConfiguration = content
		}
		let source = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: list) { view, indexPath, item in
			view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
		}
		source.supplementaryViewProvider = { view, _, indexPath in
			view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
		}
		dataSource = source
	}

	private func buildScanButton() {
		scanButton.configuration?.title = "Scan"
		scanButton.configuration?.image = UIImage(systemName: "doc.viewfinder")
		scanButton.configuration?.imagePadding = 8
		scanButton.configuration?.cornerStyle = .capsule
		scanButton.configuration?.buttonSize = .large
		scanButton.addAction(UIAction { [weak self] _ in self?.capture.scan() }, for: .primaryActionTriggered)
		scanButton.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(scanButton)
		NSLayoutConstraint.activate([
			scanButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			scanButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
			scanButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
		])
	}

	private func buildRestrictionLabel() {
		restrictionLabel.text = ConnectedArchive.restrictionSentence
		restrictionLabel.numberOfLines = 0
		restrictionLabel.textAlignment = .center
		restrictionLabel.font = .preferredFont(forTextStyle: .footnote)
		restrictionLabel.adjustsFontForContentSizeCategory = true
		restrictionLabel.textColor = .secondaryLabel
		restrictionLabel.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(restrictionLabel)
		NSLayoutConstraint.activate([
			restrictionLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
			restrictionLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
			restrictionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
		])
	}

	private func configure(_ cell: UICollectionViewListCell, _ identifier: UUID) {
		let submissions = controller.submissions
		guard let entry = submissions.entries.first(where: { $0.id == identifier }) else {
			return
		}
		let row = SubmissionRowWording.row(entry, sentFraction: submissions.progress[identifier])
		var content = UIListContentConfiguration.subtitleCell()
		content.text = row.title
		content.secondaryText = row.status
		content.secondaryTextProperties.color = .secondaryLabel
		content.image = UIImage(systemName: row.symbol)
		content.imageProperties.tintColor = switch row.tone {
		case .waiting: .tintColor
		case .archived: .systemGreen
		case .attention: .systemOrange
		}
		cell.contentConfiguration = content
	}

	private func follow() {
		withObservationTracking {
			show(controller.submissions.entries, progress: controller.submissions.progress)
			showSending(permitted: controller.sendingPermitted)
			if ScanRequestCenter.shared.isPending {
				answerScanRequest()
			}
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.follow()
			}
		}
	}

	private func show(_ entries: [SubmissionEntry], progress _: [UUID: Double]) {
		guard let dataSource else {
			return
		}
		var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
		if !entries.isEmpty {
			snapshot.appendSections([0])
			snapshot.appendItems(entries.map(\.id))
			snapshot.reconfigureItems(entries.map(\.id))
		}
		dataSource.apply(snapshot, animatingDifferences: true)
		var empty = UIContentUnavailableConfiguration.empty()
		empty.image = UIImage(systemName: "tray")
		empty.text = "Nothing Sent Yet"
		empty.secondaryText = controller.sendingPermitted
			? "Scan a letter, or add a PDF or photo. Schublade sends it to your archive, which reads and files it."
			: nil
		contentUnavailableConfiguration = entries.isEmpty ? empty : nil
	}

	/// Takes a pending scan request while this screen shows, and opens the camera if the token may
	/// send. A restricted token's screen says why it cannot, so its request is dropped.
	private func answerScanRequest() {
		guard viewIfLoaded?.window != nil, !(presentedViewController is VNDocumentCameraViewController),
		      ScanRequestCenter.shared.take(), controller.sendingPermitted
		else {
			return
		}
		guard let presented = presentedViewController else {
			capture.scan()
			return
		}
		presented.dismiss(animated: true) { [weak self] in
			self?.capture.scan()
		}
	}

	private func showSending(permitted: Bool) {
		navigationItem.rightBarButtonItem = permitted ? addItem : nil
		scanButton.isHidden = !permitted
		restrictionLabel.isHidden = permitted
	}

	func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		collectionView.deselectItem(at: indexPath, animated: true)
	}
}
