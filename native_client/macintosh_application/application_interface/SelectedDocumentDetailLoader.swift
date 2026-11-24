import ApplicationBindings

/// Holds the detail of the selected document, reads it once per document and content revision,
/// and drops an answer that a newer selection or revision overtook. Its detail is always the
/// selected document's or nil, so an action never reaches the document selected before.
final class SelectedDocumentDetailLoader {
	private let queries: any LibraryQueries
	private let onLoaded: (DocumentIdentifier, DocumentDetail?) -> Void
	private(set) var detail: DocumentDetail?
	/// The document of the last answer, its detail or that the copy holds none, or nil without a
	/// selection.
	private(set) var answeredDocument: DocumentIdentifier?
	private var selectedDocument: DocumentIdentifier?
	private var loadedDocument: DocumentIdentifier?
	private var loadedRevision: UInt64 = 0
	private var newestRequest: UInt64 = 0

	init(queries: any LibraryQueries, onLoaded: @escaping (DocumentIdentifier, DocumentDetail?) -> Void) {
		self.queries = queries
		self.onLoaded = onLoaded
	}

	/// Follows the selection, reading the detail when the document or the revision changed.
	func select(_ document: DocumentIdentifier?, revision: UInt64) {
		if document != selectedDocument {
			detail = nil
		}
		selectedDocument = document
		guard let document else {
			newestRequest &+= 1
			loadedDocument = nil
			answeredDocument = nil
			detail = nil
			return
		}
		if loadedDocument != document || loadedRevision != revision {
			reload(revision: revision)
		}
	}

	/// Reads the selected document's detail again, as after the copy changed.
	func reload(revision: UInt64) {
		guard let document = selectedDocument else {
			return
		}
		newestRequest &+= 1
		let request = newestRequest
		Task {
			let answer = try? await queries.document(document)
			guard request == newestRequest, selectedDocument == document else {
				return
			}
			loadedDocument = document
			loadedRevision = revision
			answeredDocument = document
			detail = answer
			onLoaded(document, answer)
		}
	}
}
