import ApplicationBindings

/// Everything a screen reads from the local library. Each query throws only the fault or refusal
/// its Rust counterpart returns.
protocol LibraryQueries {
	func listDocuments(
		request: ListingRequest,
		preceding: DocumentListing?
	) async throws(ApplicationFault) -> ListingAnswer
	func facets() async throws(ApplicationFault) -> LibraryFacets
	func document(_ document: DocumentIdentifier) async throws(ApplicationFault) -> DocumentDetail?
	func original(_ document: DocumentIdentifier) async throws(RepresentationRefusal) -> LocalFile
	func thumbnail(_ document: DocumentIdentifier) async throws(RepresentationRefusal) -> LocalFile?
	func extractedText(_ document: DocumentIdentifier) async throws(RepresentationRefusal) -> String
	func synchronize()
}
