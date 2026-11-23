import ApplicationBindings
import Foundation

/// Message and optional actions shown when the active listing returns zero rows.
public struct EmptyListPresentation: Equatable, Sendable {
	public let title: String
	public let detail: String
	/// Whether the list offers the device's way to bring documents into an empty archive.
	public let showsDocumentSourceButton: Bool
	public let showsSearchAllDocumentsButton: Bool

	public init(
		title: String,
		detail: String,
		showsDocumentSourceButton: Bool,
		showsSearchAllDocumentsButton: Bool
	) {
		self.title = title
		self.detail = detail
		self.showsDocumentSourceButton = showsDocumentSourceButton
		self.showsSearchAllDocumentsButton = showsSearchAllDocumentsButton
	}

	/// `scope` is nil on a page that lists no scope. Nil while the archive holds no document at all,
	/// which each device words for itself.
	public static func resolve(
		scope: LibraryScope?,
		searchText: String,
		libraryStatus: LibraryStatus?,
		libraryFault: ApplicationFault?,
		listingFault: String?
	) -> EmptyListPresentation? {
		if let listingFault {
			return EmptyListPresentation(
				title: "Could Not Read Documents",
				detail: listingFault,
				showsDocumentSourceButton: false,
				showsSearchAllDocumentsButton: false
			)
		}
		if let libraryFault {
			return EmptyListPresentation(
				title: "Library Unavailable",
				detail: LibraryFailureWording.faultSentence(libraryFault),
				showsDocumentSourceButton: false,
				showsSearchAllDocumentsButton: false
			)
		}
		let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		if !query.isEmpty {
			let inAllDocuments = scope == .allDocuments
			return EmptyListPresentation(
				title: "No Matching Documents",
				detail: inAllDocuments
					? "Try another word or clear the search field."
					: "Nothing here matched \"\(query)\".",
				showsDocumentSourceButton: false,
				showsSearchAllDocumentsButton: !inAllDocuments
			)
		}
		if case .filling = libraryStatus?.copy {
			return EmptyListPresentation(
				title: "Loading Documents…",
				detail: "Reading the archive into your local copy.",
				showsDocumentSourceButton: false,
				showsSearchAllDocumentsButton: false
			)
		}
		if (libraryStatus?.counts.documents ?? 0) > 0 {
			let (title, detail) = emptyScopeWording(scope)
			return EmptyListPresentation(
				title: title,
				detail: detail,
				showsDocumentSourceButton: false,
				showsSearchAllDocumentsButton: false
			)
		}
		return nil
	}

	/// An empty entry of an archive that holds documents elsewhere.
	private static func emptyScopeWording(_ scope: LibraryScope?) -> (String, String) {
		switch scope {
		case .recentlyAdded:
			("Nothing Added Recently", "Documents the archive received in the last 30 days appear here.")
		case .inIngestion:
			("Nothing Arriving", "Documents appear here while the archive reads them.")
		case .failed:
			("No Failed Documents", "Every document the archive received was read.")
		case nil, .allDocuments, .household, .member, .category, .tag, .sender:
			("No Documents", "No document belongs here.")
		}
	}
}
