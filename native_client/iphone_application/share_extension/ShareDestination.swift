import SubmissionQueue
import UIKit

/// Where Send hands the files, decided once as the sheet opens from the record the application keeps.
struct ShareDestination {
	let installation: SharedInstallation
	let container: SharedContainer
	let archive: ConnectedArchive

	static func resolve() -> Result<ShareDestination, ShareUnavailability> {
		guard let installation = try? SharedInstallation.read(), let container = try? installation.container() else {
			return .failure(.containerMissing)
		}
		guard let archive = container.connectedArchive() else {
			return .failure(.notConnected)
		}
		guard !archive.restricted else {
			return .failure(.restricted)
		}
		return .success(ShareDestination(installation: installation, container: container, archive: archive))
	}
}

/// Why the sheet cannot send, each said with a symbol, a title, and what to do.
enum ShareUnavailability: Error {
	case containerMissing
	case notConnected
	case restricted
	case nothingToSend

	var configuration: UIContentUnavailableConfiguration {
		var configuration = UIContentUnavailableConfiguration.empty()
		switch self {
		case .containerMissing:
			configuration.image = UIImage(systemName: "exclamationmark.triangle")
			configuration.text = "Sharing Unavailable"
			configuration.secondaryText = "Schublade cannot reach the documents it shares with this sheet. "
				+ "Reinstall Schublade."
		case .notConnected:
			configuration.image = UIImage(systemName: "tray")
			configuration.text = "No Archive Connected"
			configuration.secondaryText = "Open Schublade and connect your archive, then share again."
		case .restricted:
			configuration.image = UIImage(systemName: "lock")
			configuration.text = "This iPhone Cannot Send"
			configuration.secondaryText = ConnectedArchive.restrictionSentence
		case .nothingToSend:
			configuration.image = UIImage(systemName: "doc.questionmark")
			configuration.text = "Nothing to Send"
			configuration.secondaryText = "Schublade sends PDFs and pictures, and none was shared."
		}
		return configuration
	}
}
