import UIKit

/// The details sheet of a document page: presented at half height, remembered across pages, and
/// lifting the original above itself. The page's toolbar is repeated at the sheet's foot, because
/// the sheet covers the page's own.
final class DocumentDetailsSheet: NSObject, UISheetPresentationControllerDelegate {
	let details: DocumentDetailsViewController
	private let preferences: ApplicationPreferences
	/// The details in a navigation controller of their own, only for its toolbar.
	private let navigation: UINavigationController
	private weak var page: UIViewController?
	/// Receives how much of the page the sheet covers at its medium height, zero once it is gone.
	private let covering: (CGFloat) -> Void
	/// The height the person left the sheet at, which it takes again when the page shows again.
	private var detent = UISheetPresentationController.Detent.Identifier.medium

	init(
		details: DocumentDetailsViewController,
		toolbarItems: [UIBarButtonItem],
		page: UIViewController,
		preferences: ApplicationPreferences,
		covering: @escaping (CGFloat) -> Void
	) {
		self.details = details
		self.preferences = preferences
		self.page = page
		self.covering = covering
		navigation = UINavigationController(rootViewController: details)
		super.init()
		navigation.setNavigationBarHidden(true, animated: false)
		navigation.setToolbarHidden(false, animated: false)
		details.toolbarItems = toolbarItems
	}

	/// Whether the sheet shows when a page opens.
	var remembered: Bool {
		get { preferences.detailsShown }
		set { preferences.detailsShown = newValue }
	}

	var isPresented: Bool {
		page?.presentedViewController === navigation && !navigation.isBeingDismissed
	}

	func toggle() {
		if isPresented {
			remembered = false
			dismiss(animated: true)
		} else {
			remembered = true
			present(animated: true)
		}
	}

	func present(animated: Bool) {
		guard let page, page.presentedViewController == nil else {
			return
		}
		navigation.modalPresentationStyle = .pageSheet
		if let sheet = navigation.sheetPresentationController {
			sheet.detents = [.medium(), .large()]
			sheet.selectedDetentIdentifier = detent
			sheet.prefersGrabberVisible = true
			sheet.largestUndimmedDetentIdentifier = .medium
			sheet.prefersScrollingExpandsWhenScrolledToEdge = true
			sheet.delegate = self
		}
		details.fill(forLargeDetent: detent == .large, animated: false)
		coverPageToolbar(true)
		page.present(navigation, animated: animated) { [weak self] in
			self?.measureCovering()
		}
	}

	/// Dismisses the sheet without changing whether it is remembered, as a page does that is left.
	func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
		guard let page, page.presentedViewController === navigation else {
			completion?()
			return
		}
		covering(0)
		coverPageToolbar(false)
		page.dismiss(animated: animated, completion: completion)
	}

	/// The covered height at the medium detent only, because at the large one nothing of the
	/// original shows to be lifted.
	private func measureCovering() {
		guard let page, isPresented, detent == .medium,
		      let sheetView = navigation.sheetPresentationController?.presentedView
		else {
			return
		}
		let sheetTop = page.view.convert(sheetView.bounds, from: sheetView).minY
		covering(max(0, page.view.bounds.maxY - sheetTop - page.view.safeAreaInsets.bottom))
	}

	func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheet: UISheetPresentationController) {
		detent = sheet.selectedDetentIdentifier ?? .medium
		details.fill(forLargeDetent: detent == .large, animated: true)
		measureCovering()
	}

	func presentationControllerDidDismiss(_: UIPresentationController) {
		remembered = false
		covering(0)
		coverPageToolbar(false)
	}

	func presentationControllerWillDismiss(_: UIPresentationController) {
		coverPageToolbar(false)
	}

	/// The page's toolbar hides under the sheet's copy of it, in the same place, so VoiceOver finds
	/// one Share and one Details. It returns under the sheet as the sheet leaves.
	private func coverPageToolbar(_ covered: Bool) {
		page?.navigationController?.setToolbarHidden(covered, animated: false)
	}
}
