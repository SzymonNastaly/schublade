import ApplicationBindings

/// Plain user-facing sentences for runtime faults, unavailable document representations, and the
/// condition of a document the archive has not archived.
public enum LibraryFailureWording {
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

	/// An original that arrived but is neither a PDF nor an image the device can draw.
	public static let unreadableOriginalPlaceholder = RepresentationPlaceholder(
		title: "This Original Cannot Be Shown",
		detail: "Open it in its default application, or open the document in the browser.",
		canRetry: false,
		allowsTokenReplacement: false
	)

	public static func originalRefusalPlaceholder(
		_ refusal: RepresentationRefusal,
		device: DeviceWording
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
				"The Original Is Not on \(device.titlePhrase)",
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
				"The Original Is Not on \(device.titlePhrase)",
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
