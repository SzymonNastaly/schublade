import SubmissionQueue
import UIKit

/// The library's bar items: the scope filter, the search field, and Scan in the toolbar, and More
/// in the navigation bar. Each item is made once, so an open menu stays open while the copy changes.
final class LibraryCommands: NSObject {
	/// What the bars hold, which changes only with the token's permission and an empty archive.
	struct Arrangement: Equatable {
		let sendingPermitted: Bool
		let showsFilter: Bool
	}

	private weak var screen: LibraryViewController?
	private let capture: DocumentCapture
	private let scopeElements: () -> [UIMenuElement]
	private var arranged: Arrangement?

	/// The scope menu reads the facets when it opens, so a change of the copy never rebuilds it
	/// under the person's finger.
	private lazy var filterItem: UIBarButtonItem = {
		let menu = UIMenu(title: "Show", children: [
			UIDeferredMenuElement.uncached { [weak self] completion in
				completion(self?.scopeElements() ?? [])
			},
		])
		let item = UIBarButtonItem(title: "Show", image: UIImage(systemName: "line.3.horizontal.decrease"), menu: menu)
		item.accessibilityIdentifier = "library.filter"
		if #available(iOS 26, *) {
			item.sharesBackground = false
		}
		return item
	}()

	private lazy var scanItem: UIBarButtonItem = {
		let item = UIBarButtonItem(
			title: "Scan",
			image: UIImage(systemName: "doc.viewfinder"),
			primaryAction: UIAction(title: "Scan") { [weak self] _ in self?.capture.scan(animated: true) },
			menu: UIMenu(children: importActions())
		)
		if #available(iOS 26, *) {
			item.style = .prominent
		} else {
			item.style = .done
		}
		item.accessibilityIdentifier = "library.scan"
		return item
	}()

	private lazy var moreItem: UIBarButtonItem = {
		let item = UIBarButtonItem(title: "More", image: UIImage(systemName: "ellipsis"), menu: UIMenu())
		item.accessibilityIdentifier = "library.more"
		return item
	}()

	init(screen: LibraryViewController, capture: DocumentCapture, scopeElements: @escaping () -> [UIMenuElement]) {
		self.screen = screen
		self.capture = capture
		self.scopeElements = scopeElements
	}

	/// Puts the items in the bars when what they hold changes. From iOS 26 the search field sits in
	/// the toolbar between the filter and Scan; before, it stays under the large title.
	func arrange(_ arrangement: Arrangement) {
		guard let screen, arrangement != arranged else {
			return
		}
		let item = screen.navigationItem
		arranged = arrangement
		var toolbar: [UIBarButtonItem] = arrangement.showsFilter ? [filterItem] : []
		if #available(iOS 26, *) {
			toolbar.append(item.searchBarPlacementBarButtonItem)
		} else {
			toolbar.append(.flexibleSpace())
		}
		if arrangement.sendingPermitted {
			toolbar.append(scanItem)
		}
		screen.setToolbarItems(toolbar, animated: screen.view.window != nil)
		moreItem.menu = UIMenu(children: moreElements(sendingPermitted: arrangement.sendingPermitted))
		item.rightBarButtonItem = moreItem
	}

	/// Marks the filter while it shows less than all documents.
	func showFiltering(_ filtering: Bool) {
		if filterItem.isSelected != filtering {
			filterItem.isSelected = filtering
		}
	}

	private func importActions() -> [UIMenuElement] {
		[
			UIAction(title: "Choose Photos", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
				self?.capture.choosePhotos()
			},
			UIAction(title: "Choose Files", image: UIImage(systemName: "folder")) { [weak self] _ in
				self?.capture.chooseFiles()
			},
		]
	}

	/// Photos and Files while the token may send. Otherwise the one sentence that says why it cannot,
	/// until Settings says it.
	private func moreElements(sendingPermitted: Bool) -> [UIMenuElement] {
		guard sendingPermitted else {
			return [
				UIAction(title: "Sending Unavailable", image: UIImage(systemName: "info.circle")) { [weak self] _ in
					let alert = UIAlertController(
						title: "This iPhone Cannot Send",
						message: ConnectedArchive.restrictionSentence,
						preferredStyle: .alert
					)
					alert.addAction(UIAlertAction(title: "OK", style: .default))
					self?.screen?.present(alert, animated: true)
				},
			]
		}
		return [UIMenu(options: .displayInline, children: importActions())]
	}
}
