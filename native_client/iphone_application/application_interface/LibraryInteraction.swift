import ApplicationBindings
import LibraryPresentation
import UIKit

/// What a person does with the library's rows: a tap opens a document or the form for a new
/// token in Settings, a touch and hold lifts a document's page with its actions, and a row scrolled
/// away gives up the reading of its picture.
final class LibraryInteraction: NSObject, UICollectionViewDelegate {
	private weak var screen: LibraryViewController?
	private let list: LibraryList
	private let thumbnails: ThumbnailStore
	private let gateway: ApplicationGateway
	/// The document whose context menu shows, which a tap on its page opens.
	private var menuRow: DocumentRow?

	init(screen: LibraryViewController, list: LibraryList, thumbnails: ThumbnailStore, gateway: ApplicationGateway) {
		self.screen = screen
		self.list = list
		self.thumbnails = thumbnails
		self.gateway = gateway
	}

	func collectionView(_: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
		list.destination(at: indexPath) != nil
	}

	func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		switch list.destination(at: indexPath) {
		case let .document(document, title, opening)?:
			screen?.open(document, title: title, opening: opening)
		case .tokenReplacement?:
			screen?.openSettings(replacingToken: true)
		case let .scope(scope)?:
			screen?.chooseSuggested(scope)
		case nil:
			break
		}
	}

	func collectionView(_: UICollectionView, didEndDisplaying _: UICollectionViewCell, forItemAt indexPath: IndexPath) {
		if case let .document(document)? = list.item(at: indexPath) {
			thumbnails.forget(document)
		}
	}

	func collectionView(
		_ collectionView: UICollectionView,
		contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
		point _: CGPoint
	) -> UIContextMenuConfiguration? {
		guard indexPaths.count == 1, let indexPath = indexPaths.first,
		      case let .document(document)? = list.item(at: indexPath),
		      let row = list.row(of: document)
		else {
			return nil
		}
		let width = collectionView.bounds.inset(by: collectionView.layoutMargins).width
		let picture = thumbnails.picture(for: document) { _ in }
		let cell = collectionView.cellForItem(at: indexPath)
		menuRow = row
		return UIContextMenuConfiguration(identifier: nil) { [gateway] in
			DocumentPreviewViewController(gateway: gateway, document: document, picture: picture, width: width)
		} actionProvider: { [weak self] _ in
			self?.menu(for: row, source: cell)
		}
	}

	func collectionView(
		_: UICollectionView,
		willPerformPreviewActionForMenuWith _: UIContextMenuConfiguration,
		animator: any UIContextMenuInteractionCommitAnimating
	) {
		guard let row = menuRow else {
			return
		}
		animator.addCompletion { [weak self] in
			self?.screen?.open(row.document, title: row.title, opening: .listed)
		}
	}

	/// Share, the sender's other documents, and the document in the browser. The last two need the
	/// document's detail, which is read when the menu opens.
	private func menu(for row: DocumentRow, source: UIView?) -> UIMenu {
		let share = UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
			guard let self else {
				return
			}
			OriginalCopies.share(
				row.document,
				fileName: row.suggestedFileName,
				gateway: gateway,
				presenter: screen,
				source: source
			)
		}
		let detailed = UIDeferredMenuElement.uncached { [weak self, gateway] completion in
			Task {
				guard let detail = try? await gateway.document(row.document) else {
					completion([])
					return
				}
				completion(self?.detailActions(detail) ?? [])
			}
		}
		return UIMenu(children: [share, detailed])
	}

	private func detailActions(_ detail: DocumentDetail) -> [UIMenuElement] {
		var actions: [UIMenuElement] = []
		if let sender = detail.sender {
			actions.append(UIAction(
				title: "More from \(sender.name)",
				image: UIImage(systemName: "building.2")
			) { [weak self] _ in
				self?.screen?.choose(sender)
			})
		}
		if let page = URL(string: detail.archivePage) {
			actions.append(UIAction(title: "Open in Browser", image: UIImage(systemName: "safari")) { _ in
				UIApplication.shared.open(page)
			})
		}
		return actions
	}
}
