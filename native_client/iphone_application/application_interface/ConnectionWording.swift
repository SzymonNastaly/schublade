import ApplicationBindings

/// The sentences of the welcome screen and the replace form, as the Mac words them.
enum ConnectionWording {
	static func refusalSentence(_ refusal: ConnectionRefusal) -> String {
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
			"This archive does not support the app yet. Update your archive first."
		case let .ArchiveDiffers(connectedHost):
			"This iPhone is already connected to \(connectedHost)."
		case let .CredentialStorageFailed(detail):
			"The token could not be saved in the Keychain: \(detail)"
		case let .Application(fault):
			"Schublade could not connect: \(fault)"
		}
	}
}
