import ApplicationBindings

/// Plain user-facing sentences for startup failures, runtime faults, command refusals, and
/// unavailable document representations.
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

	public static func faultSentence(_ fault: ApplicationFault) -> String {
		switch fault {
		case .Stopped:
			"Schublade stopped."
		case let .StoreFailed(detail):
			"Local storage error: \(detail)"
		case let .Unexpected(detail):
			"Unexpected application error: \(detail)"
		}
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
			faultSentence(fault)
		}
	}

	public static func originalRefusalPlaceholder(
		_ refusal: RepresentationRefusal
	) -> RepresentationPlaceholder {
		switch refusal {
		case .DocumentUnknown:
			placeholder("Document Not Found", "This document is no longer in the local copy.")
		case .NotAvailableYet:
			placeholder(
				"Original Not Ready Yet",
				"The archive has not finished preparing this document's PDF yet.",
				retry: true
			)
		case .ArchiveUnreachable:
			placeholder(
				"The Original Is Not on This Mac",
				"Connect to the internet to download and view this document.",
				retry: true
			)
		case .NoLongerArchived:
			placeholder(
				"Original No Longer in Archive",
				"This document was removed from the archive or its original file is missing."
			)
		case .CredentialRefused:
			placeholder(
				"Token Refused",
				"Schublade refused the current token. Replace the token to download originals.",
				replaceToken: true
			)
		case .NotConnected:
			placeholder(
				"The Original Is Not on This Mac",
				"Connect to a readable archive to download originals.",
				replaceToken: true
			)
		case .ArchiveOutdated:
			placeholder(
				"Archive Update Required",
				"Update your archive to download originals from this application."
			)
		case .ContentDiffers:
			placeholder(
				"File Verification Failed",
				"The downloaded file did not match the document's digest, so nothing was kept.",
				retry: true
			)
		case let .StorageFailed(detail):
			placeholder("Could Not Save Original", detail, retry: true)
		case let .Application(fault):
			placeholder("Original Unavailable", faultSentence(fault), retry: fault != .Stopped)
		}
	}

	public static func extractedTextRefusalPlaceholder(
		_ refusal: RepresentationRefusal
	) -> RepresentationPlaceholder {
		switch refusal {
		case .DocumentUnknown, .NotAvailableYet, .NoLongerArchived:
			placeholder(
				"No Extracted Text",
				"This document has no extracted text yet.",
				retry: refusal == .NotAvailableYet
			)
		case .ArchiveUnreachable:
			placeholder(
				"Text Not Downloaded Yet",
				"Connect to the internet to fetch the extracted text.",
				retry: true
			)
		case .CredentialRefused:
			placeholder("Token Refused", "Replace the token to download extracted text.", replaceToken: true)
		case .NotConnected:
			placeholder(
				"Text Unavailable",
				"Connect to a readable archive to download extracted text.",
				replaceToken: true
			)
		case .ArchiveOutdated:
			placeholder("Archive Update Required", "Update your archive to fetch extracted text.")
		case .ContentDiffers:
			placeholder("Text Unavailable", "The archive returned unexpected data.", retry: true)
		case let .StorageFailed(detail):
			placeholder("Could Not Read Text", detail, retry: true)
		case let .Application(fault):
			placeholder("Text Unavailable", faultSentence(fault), retry: fault != .Stopped)
		}
	}

	public static func stageText(_ stage: IngestionStage) -> String {
		switch stage {
		case .awaitingRendering:
			"Waiting to print email"
		case .processing:
			"Queued for processing"
		case .extracting:
			"Extracting text"
		case .recognizingText:
			"Recognizing text"
		case .classifying:
			"Classifying document"
		case .other:
			"Processing document"
		}
	}

	public static func failureText(_ reason: FailureReason) -> String {
		switch reason {
		case .unreadableFile:
			"This file could not be opened."
		case .pageLimitExceeded:
			"This PDF needs text recognition on more than 50 pages, which is the limit."
		case .unreadablePage:
			"A page could not be read in any orientation."
		case .processingError:
			"Processing failed. Try again."
		case .other:
			"Ingestion failed."
		}
	}

	private static func placeholder(
		_ title: String,
		_ detail: String,
		retry: Bool = false,
		replaceToken: Bool = false
	) -> RepresentationPlaceholder {
		RepresentationPlaceholder(
			title: title,
			detail: detail,
			canRetry: retry,
			allowsTokenReplacement: replaceToken
		)
	}
}
