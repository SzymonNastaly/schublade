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
		case let .failed(empty):
			var configuration = UIContentUnavailableConfiguration.empty()
			configuration.image = UIImage(systemName: "exclamationmark.triangle")
			configuration.text = empty.title
			configuration.secondaryText = empty.detail
			addPlainButton("Try Again", to: &configuration, perform: actions.readAgain)
			return configuration
		case let .empty(empty):
			var configuration: UIContentUnavailableConfiguration = searching ? .search() : .empty()
			if !searching {
				configuration.image = UIImage(systemName: "tray")
			}
			configuration.text = empty.title
			configuration.secondaryText = empty.detail
			if empty.showsSearchAllDocumentsButton {
				addPlainButton("Search All Documents", to: &configuration, perform: actions.searchAllDocuments)
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

	private static func addPlainButton(
		_ title: String,
		to configuration: inout UIContentUnavailableConfiguration,
		perform: @escaping () -> Void
	) {
		configuration.button = .plain()
		configuration.button.title = title
		configuration.buttonProperties.primaryAction = UIAction { _ in perform() }
	}
}
