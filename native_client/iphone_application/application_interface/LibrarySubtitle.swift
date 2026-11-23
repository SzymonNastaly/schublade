import ApplicationBindings
import LibraryPresentation

/// The one line under the library's title from iOS 26: how much of the text a search reaches, then
/// a copy that fills or an archive out of reach, then how many documents the list shows. A refused
/// token and an outdated archive are the attention row's to say.
enum LibrarySubtitle {
	static func resolve(
		status: LibraryStatus,
		searchText: String,
		documentCount: UInt32,
		context: WordingContext
	) -> String? {
		if let notice = LibraryScopePresentation.textIndexingNotice(searchText: searchText, counts: status.counts) {
			return notice
		}
		let filling = if case .filling = status.copy {
			true
		} else {
			false
		}
		let outOfReach = switch status.archive {
		case .configured(_, _, .unreachable, _, _), .configured(_, _, .deferred, _, _): true
		default: false
		}
		if filling || outOfReach {
			return StatusLinePresentation.resolve(library: status, fault: nil, uploadingFiles: 0, context: context).text
		}
		guard documentCount > 0 else {
			return nil
		}
		return DocumentFormatting.countText(UInt64(documentCount), singular: "document")
	}
}
