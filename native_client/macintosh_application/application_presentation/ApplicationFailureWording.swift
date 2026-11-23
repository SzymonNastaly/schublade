import ApplicationBindings
import LibraryPresentation

/// Plain user-facing sentences for startup failures and connection refusals, as the Mac words them.
public enum ApplicationFailureWording {
	private static let reopenRemedy = "Quit Schublade and open it again."

	public static func startFailureWording(_ failure: ApplicationStartFailure) -> StartFailureWording {
		switch failure {
		case let .DataDirectoryUnavailable(detail):
			StartFailureWording(
				explanation: "Schublade could not create its folder in Application Support.",
				remedy: "Check that your disk has free space. \(reopenRemedy)",
				detail: detail
			)
		case let .CacheDirectoryUnavailable(detail):
			StartFailureWording(
				explanation: "Schublade could not create its cache folder.",
				remedy: "Check that your disk has free space. \(reopenRemedy)",
				detail: detail
			)
		case .DatabaseInUse:
			StartFailureWording(
				explanation: "Another copy of Schublade is already running on this Mac with the same data.",
				remedy: "Use the running copy or quit it before opening this one.",
				detail: nil
			)
		case .DatabaseNewerThanApplication:
			StartFailureWording(
				explanation:
				"A newer version of Schublade ran on this Mac before, and this older version cannot read what it saved.",
				remedy: "Install the newest version of Schublade and open it.",
				detail: nil
			)
		case let .DatabaseUnusable(detail):
			StartFailureWording(
				explanation: "Schublade could not open the file where it keeps track of your folders.",
				remedy: reopenRemedy,
				detail: detail
			)
		case let .WatcherUnavailable(detail):
			StartFailureWording(
				explanation: "Schublade could not start watching your folders for new files.",
				remedy: reopenRemedy,
				detail: detail
			)
		case let .Unexpected(detail):
			StartFailureWording(
				explanation: "Schublade could not start.",
				remedy: reopenRemedy,
				detail: detail
			)
		}
	}

	public static func startFailureSentence(_ failure: ApplicationStartFailure) -> String {
		let wording = startFailureWording(failure)
		if let detail = wording.detail, !detail.isEmpty {
			return "\(wording.combinedSentence) (\(detail))"
		}
		return wording.combinedSentence
	}

	public static func connectionRefusalSentence(_ refusal: ConnectionRefusal) -> String {
		switch refusal {
		case .AddressInvalid:
			"This is not an archive address. Copy the address from your browser, such as https://archive.example.org."
		case .TokenRefused:
			"Schublade refused this token. Check that you copied all of it and that it was not revoked."
		case .TokenInsufficient:
			"This token cannot read or add documents. Issue another token in Settings."
		case .ArchiveUnreachable:
			"The archive could not be reached. Check the address and your internet connection."
		case .ArchiveUnavailable:
			"The archive is busy right now. Try again in a few minutes."
		case .ArchiveFailed:
			"The archive had a problem answering. Try again in a few minutes."
		case .NotAnArchive:
			"This address answers, but not like a Schublade archive. Check that it is the address of your archive."
		case .ArchiveOutdated:
			"This archive does not support the desktop application yet. Update your archive first."
		case let .ArchiveDiffers(connectedHost):
			"This Mac already collects folders into \(connectedHost)."
		case let .CredentialStorageFailed(detail):
			"The token could not be saved in the Keychain: \(detail)"
		case let .Application(fault):
			LibraryFailureWording.faultSentence(fault)
		}
	}
}
