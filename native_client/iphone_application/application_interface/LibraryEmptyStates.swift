import LibraryPresentation
import UIKit

/// What the library shows in place of its rows.
enum LibraryEmptyStates {
	struct Actions {
		let scan: () -> Void
		let searchAllDocuments: () -> Void
		/// Reads a listing that failed again.
		let readAgain: () -> Void
	}

	static func configuration(
		_ state: LibraryListState,
		sendingPermitted: Bool,
		searching: Bool,
		actions: Actions
	) -> UIContentUnavailableConfiguration? {
		switch state {
		case .documents:
			return nil
		case .awaitingListing:
			return .loading()
		case let .fillingCopy(status):
			var loading = UIContentUnavailableConfiguration.loading()
			loading.text = "Loading Documents…"
			loading.secondaryText = status.text
			return loading
		case let .empty(empty), let .failed(empty):
			var configuration = UIContentUnavailableConfiguration.search()
			if case .failed = state {
				configuration = .empty()
				configuration.image = UIImage(systemName: "exclamationmark.triangle")
			} else if !searching {
				configuration = .empty()
				configuration.image = UIImage(systemName: "tray")
			}
			configuration.text = empty.title
			configuration.secondaryText = empty.detail
			if case .failed = state {
				configuration.button = .plain()
				configuration.button.title = "Try Again"
				configuration.buttonProperties.primaryAction = UIAction { _ in actions.readAgain() }
			} else if empty.showsSearchAllDocumentsButton {
				configuration.button = .plain()
				configuration.button.title = "Search All Documents"
				configuration.buttonProperties.primaryAction = UIAction { _ in actions.searchAllDocuments() }
			}
			return configuration
		case .emptyArchive:
			var configuration = UIContentUnavailableConfiguration.empty()
			configuration.image = UIImage(named: "DrawerGlyph")
			configuration.imageProperties.maximumSize = CGSize(width: 64, height: 64)
			configuration.imageProperties.tintColor = .tertiaryLabel
			configuration.text = "No Documents Yet"
			configuration.secondaryText = sendingPermitted
				? "Scan a letter, or share a PDF or photo with Schublade. Your archive reads it, names it, and files it."
				: "Documents added to your archive in the browser appear here."
			if sendingPermitted {
				configuration.button = .filled()
				configuration.button.title = "Scan"
				configuration.button.image = UIImage(systemName: "doc.viewfinder")
				configuration.button.imagePadding = 8
				configuration.button.cornerStyle = .capsule
				configuration.buttonProperties.primaryAction = UIAction { _ in actions.scan() }
			}
			return configuration
		}
	}
}
