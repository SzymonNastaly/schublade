import ApplicationBindings
import LibraryPresentation
import UIKit

/// The document page's toolbar: Share, and the item that shows or hides the details. The page and
/// the details sheet each hold one, with the items in the same places, so the items stay put while
/// the sheet rises behind them and the sheet's own item reads as selected.
final class DocumentFileActions {
	private let gateway: ApplicationGateway
	private let document: DocumentIdentifier
	private weak var page: UIViewController?
	private let toggleDetails: () -> Void

	var detail: DocumentDetailPresentation? {
		didSet {
			for item in pageItems + sheetItems {
				item.isEnabled = detail != nil
			}
		}
	}

	private(set) lazy var pageItems = items(detailsShown: false)
	private(set) lazy var sheetItems = items(detailsShown: true)

	init(
		gateway: ApplicationGateway,
		document: DocumentIdentifier,
		page: UIViewController,
		toggleDetails: @escaping () -> Void
	) {
		self.gateway = gateway
		self.document = document
		self.page = page
		self.toggleDetails = toggleDetails
	}

	private func items(detailsShown: Bool) -> [UIBarButtonItem] {
		let share = UIBarButtonItem(title: "Share", image: UIImage(systemName: "square.and.arrow.up"))
		share.primaryAction = UIAction(title: "Share", image: share.image) { [weak self, weak share] _ in
			self?.share(from: share)
		}
		let details = UIBarButtonItem(
			title: "Details",
			image: UIImage(systemName: "info.circle"),
			primaryAction: UIAction(title: "Details") { [weak self] _ in self?.toggleDetails() }
		)
		details.isSelected = detailsShown
		share.accessibilityIdentifier = "document.share"
		details.accessibilityIdentifier = detailsShown ? "document.details.hide" : "document.details.show"
		for item in [share, details] {
			item.isEnabled = detail != nil
		}
		return [share, .flexibleSpace(), details]
	}

	private func share(from item: UIBarButtonItem?) {
		guard let detail else {
			return
		}
		// The sheet presents the share sheet while it shows, because the page presents the sheet.
		var presenter = page
		while let presented = presenter?.presentedViewController, !presented.isBeingDismissed {
			presenter = presented
		}
		OriginalCopies.share(
			document,
			fileName: detail.suggestedFileName,
			gateway: gateway,
			presenter: presenter,
			source: item
		)
	}
}
