import SubmissionQueue
import UIKit

final class LibraryCommands: NSObject {
	private weak var screen: LibraryViewController?
	private let capture: DocumentCapture

	private lazy var scanItem: UIBarButtonItem = {
		let item = UIBarButtonItem(
			title: "Scan",
			image: UIImage(systemName: "doc.viewfinder"),
			primaryAction: UIAction(title: "Scan") { [weak self] _ in self?.capture.scan() }
		)
		if #available(iOS 26, *) {
			item.style = .prominent
		} else {
			item.style = .done
		}
		item.accessibilityIdentifier = "library.scan"
		return item
	}()

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

	private lazy var restrictionItem = UIBarButtonItem(
		title: "Sending Unavailable",
		image: UIImage(systemName: "info.circle"),
		primaryAction: UIAction(title: "Sending Unavailable") { [weak self] _ in
			let alert = UIAlertController(
				title: "Sending Unavailable",
				message: ConnectedArchive.restrictionSentence,
				preferredStyle: .alert
			)
			alert.addAction(UIAlertAction(title: "OK", style: .default))
			self?.screen?.present(alert, animated: true)
		}
	)

	init(screen: LibraryViewController, capture: DocumentCapture) {
		self.screen = screen
		self.capture = capture
	}

	func toolbarItems(sendingPermitted: Bool) -> [UIBarButtonItem] {
		sendingPermitted
			? [addItem, .flexibleSpace(), scanItem]
			: [.flexibleSpace(), restrictionItem, .flexibleSpace()]
	}

	func filterItem(menu: UIMenu, filtering: Bool) -> UIBarButtonItem {
		let symbol = filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
		let item = UIBarButtonItem(title: "Show", image: UIImage(systemName: symbol), menu: menu)
		item.accessibilityIdentifier = "library.filter"
		return item
	}
}

extension LibraryCommands: UISearchResultsUpdating, UISearchControllerDelegate {
	func updateSearchResults(for searchController: UISearchController) {
		screen?.searchTextChanged(searchController.searchBar.text ?? "")
	}

	func willPresentSearchController(_: UISearchController) {
		screen?.navigationController?.setToolbarHidden(true, animated: true)
	}

	func willDismissSearchController(_: UISearchController) {
		screen?.navigationController?.setToolbarHidden(false, animated: true)
	}
}
