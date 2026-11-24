import AppKit
import ApplicationBindings
import ApplicationPresentation

/// The scenes of one selected document: its original, a picture, its text with and without a
/// search, and the inspector at its edges.
extension ScreenRenderer {
	func renderLibraryDocumentScreens() async throws {
		try await renderWorkspaceScene(
			name: "library_document_pdf",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(
				destination: .library(.allDocuments, title: nil),
				selectedDocument: fixtures.invoiceIdentifier,
				readerTab: .original,
				inspectorVisible: true
			),
			queries: fixtures.queries.scene(listing: fixtures.sampleListing)
		)

		try await renderWorkspaceScene(
			name: "library_minimum_width",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(
				destination: .library(.allDocuments, title: nil),
				selectedDocument: fixtures.invoiceIdentifier,
				readerTab: .original,
				inspectorVisible: true
			),
			queries: fixtures.queries.scene(listing: fixtures.sampleListing),
			windowSize: Self.windowSizeAtMinimumWidth
		)

		try await renderWorkspaceScene(
			name: "library_document_image",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(
				destination: .library(.allDocuments, title: nil),
				selectedDocument: fixtures.receiptIdentifier,
				readerTab: .original,
				inspectorVisible: true
			),
			queries: fixtures.queries.scene(listing: fixtures.sampleListing)
		)
	}

	/// The extracted text with a search's match marked, and without a search beside no inspector, so
	/// the column's limit shows.
	func renderExtractedTextScreens() async throws {
		try await renderWorkspaceScene(
			name: "library_search_text",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(
				destination: .library(.category(category: CategoryIdentifier(value: "c1")), title: "Invoice"),
				searchText: "Haftpflichtversicherung",
				selectedDocument: fixtures.invoiceIdentifier,
				readerTab: .text,
				inspectorVisible: true
			),
			queries: fixtures.queries.scene(listing: fixtures.searchListing)
		)

		try await renderWorkspaceScene(
			name: "library_document_text",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(
				destination: .library(.allDocuments, title: nil),
				selectedDocument: fixtures.invoiceIdentifier,
				readerTab: .text,
				inspectorVisible: false
			),
			queries: fixtures.queries.scene(listing: fixtures.sampleListing)
		)
	}

	/// The inspector at its edges: a title of four lines, the reader without the inspector, and a
	/// fact under the pointer beside one just copied.
	func renderReaderAndInspectorScreens() async throws {
		let invoiceNavigation = LibraryNavigationState(
			destination: .library(.allDocuments, title: nil),
			selectedDocument: fixtures.invoiceIdentifier,
			readerTab: .original,
			inspectorVisible: true
		)
		try await renderWorkspaceScene(
			name: "library_document_long_title",
			statuses: fixtures.makeStatuses(),
			navigation: invoiceNavigation,
			queries: fixtures.queries.scene(
				listing: fixtures.sampleListing,
				replacingDetails: [fixtures.invoiceIdentifier: fixtures.invoiceDetailWithLongTitle]
			)
		)

		var withoutInspector = invoiceNavigation
		withoutInspector.inspectorVisible = false
		try await renderWorkspaceScene(
			name: "library_reader_without_inspector",
			statuses: fixtures.makeStatuses(),
			navigation: withoutInspector,
			queries: fixtures.queries.scene(listing: fixtures.sampleListing)
		)

		try await renderWorkspaceScene(
			name: "library_inspector_copy",
			statuses: fixtures.makeStatuses(),
			navigation: invoiceNavigation,
			queries: fixtures.queries.scene(listing: fixtures.sampleListing),
			pointedRow: "IBAN",
			copiedRow: "Amount"
		)
	}
}
