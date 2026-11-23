import ApplicationBindings
import LibraryPresentation

/// What the reader shows in place of a page or a text: nothing selected, a representation on its
/// way, or one the copy cannot show, with a picture that says why.
public extension EmptyStatePresentation {
	static let noDocumentSelected = EmptyStatePresentation(
		picture: .symbol("doc.text"),
		title: "No Document Selected",
		detail: "",
		action: nil
	)

	static let loadingOriginal = EmptyStatePresentation(
		picture: .progress,
		title: "Loading Original…",
		detail: "",
		action: nil
	)

	static let loadingText = EmptyStatePresentation(
		picture: .progress,
		title: "Loading Text…",
		detail: "",
		action: nil
	)

	static let unreadableOriginal = representation(LibraryFailureWording.unreadableOriginalPlaceholder, symbol: "doc")

	static func originalRefusal(_ refusal: RepresentationRefusal, device: DeviceWording) -> EmptyStatePresentation {
		representation(
			LibraryFailureWording.originalRefusalPlaceholder(refusal, device: device),
			symbol: symbol(for: refusal)
		)
	}

	/// An email whose PDF the archive has not printed yet.
	static func unprintedEmail(device: DeviceWording) -> EmptyStatePresentation {
		representation(
			LibraryFailureWording.originalRefusalPlaceholder(.NotAvailableYet, device: device),
			symbol: "envelope"
		)
	}

	static func textRefusal(_ refusal: RepresentationRefusal) -> EmptyStatePresentation {
		representation(LibraryFailureWording.extractedTextRefusalPlaceholder(refusal), symbol: symbol(for: refusal))
	}

	private static func representation(
		_ placeholder: RepresentationPlaceholder,
		symbol: String
	) -> EmptyStatePresentation {
		let action: EmptyStateAction? = if placeholder.allowsTokenReplacement {
			.replaceToken
		} else if placeholder.canRetry {
			.tryAgain
		} else {
			nil
		}
		return EmptyStatePresentation(
			picture: .symbol(symbol),
			title: placeholder.title,
			detail: placeholder.detail,
			action: action
		)
	}

	private static func symbol(for refusal: RepresentationRefusal) -> String {
		switch refusal {
		case .ArchiveUnreachable: "wifi.slash"
		case .NotConnected, .CredentialRefused: "key"
		case .NotAvailableYet: "hourglass"
		case .DocumentUnknown, .NoLongerArchived: "doc.questionmark"
		case .ArchiveOutdated, .ContentDiffers, .StorageFailed, .Application: "exclamationmark.triangle"
		}
	}
}
