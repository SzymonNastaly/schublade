import ApplicationBindings
import ApplicationPresentation
import Foundation
import LibraryPresentation
import Testing

/// The list's empty states, its search field, its context menu, and the place the window reopens on.
struct LibraryListPresentationTests {
	@Test func anEmptyArchiveIsOnePageThatOffersAFolderOnlyToACollectingMac() throws {
		let content = WindowContent.resolve(
			situation: .running(WindowContentAndSidebarTests.makeStatuses(documents: 0)),
			navigation: LibraryNavigationState(),
			facets: nil,
			context: WindowContentAndSidebarTests.fixedContext()
		)
		guard case let .libraryWorkspace(workspace) = content else {
			Issue.record("Expected library workspace for an empty archive")
			return
		}
		#expect(workspace.detailMode == .emptyArchive(offersFolders: true))
		let page = try #require(EmptyStatePresentation.page(workspace.detailMode))
		#expect(page.picture == .emptyDrawer)
		#expect(page.action == .addFolder)
		#expect(EmptyStatePresentation.page(.emptyArchive(offersFolders: false))?.action == nil)
	}

	@Test func aSearchWithoutResultOffersAllDocumentsOutsideAllDocuments() {
		let navigation = LibraryNavigationState(
			destination: .library(.category(category: CategoryIdentifier(value: "c1")), title: "Invoice"),
			searchText: "Nordbank"
		)
		let noResult = EmptyStatePresentation.list(
			navigation: navigation,
			libraryStatus: WindowContentAndSidebarTests.makeStatuses().library,
			libraryFault: nil,
			listingFault: nil,
			hasCollector: true
		)
		#expect(noResult.picture == .symbol("magnifyingglass"))
		#expect(noResult.action == .searchAllDocuments)
	}

	@Test func theSearchFieldNamesTheScopeItSearches() {
		let invoice = WindowContent.resolve(
			situation: .running(WindowContentAndSidebarTests.makeStatuses()),
			navigation: LibraryNavigationState(
				destination: .library(.category(category: CategoryIdentifier(value: "c1")), title: "Invoice")
			),
			facets: WindowContentAndSidebarTests.makeFacets(),
			context: WindowContentAndSidebarTests.fixedContext()
		)
		let folder = WindowContent.resolve(
			situation: .running(WindowContentAndSidebarTests.makeStatuses()),
			navigation: LibraryNavigationState(destination: .folder(FolderIdentifier(value: 1))),
			facets: WindowContentAndSidebarTests.makeFacets(),
			context: WindowContentAndSidebarTests.fixedContext()
		)
		guard case let .libraryWorkspace(invoiceWorkspace) = invoice,
		      case let .libraryWorkspace(folderWorkspace) = folder
		else {
			Issue.record("Expected library workspaces")
			return
		}
		#expect(invoiceWorkspace.searchPlaceholder == "Search Invoice")
		#expect(folderWorkspace.searchPlaceholder == "Search All Documents")
	}

	@Test func theRememberedPlaceSurvivesItsStoredValuesAndFallsBackWhenItsScopeIsGone() throws {
		let invoice = CategoryIdentifier(value: "c1")
		let reading = LibraryNavigationState(
			destination: .library(.category(category: invoice), title: "Invoice"),
			selectedDocument: DocumentIdentifier(value: "d7")
		)
		let place = try #require(RememberedLibraryPlace(reading))
		let restored = try #require(RememberedLibraryPlace(storedValues: place.storedValues))
		var navigation = LibraryNavigationState()
		restored.restore(into: &navigation)
		#expect(navigation.destination == .library(.category(category: invoice), title: "Invoice"))
		#expect(navigation.selectedDocument == DocumentIdentifier(value: "d7"))
		#expect(restored.isHeld(by: WindowContentAndSidebarTests.makeFacets()))
		#expect(!RememberedLibraryPlace(
			scope: .category(category: CategoryIdentifier(value: "gone")),
			scopeName: "Gone",
			document: nil
		)
		.isHeld(by: WindowContentAndSidebarTests.makeFacets()))

		let sender = LibraryNavigationState(
			destination: .library(.sender(sender: SenderIdentifier(value: "s1")), title: "Nordbank AG"),
			selectedDocument: DocumentIdentifier(value: "d7")
		)
		#expect(RememberedLibraryPlace(sender)?.scope == .allDocuments)
		#expect(RememberedLibraryPlace(LibraryNavigationState(destination: .needsAttention)) == nil)
	}

	@Test func aRowOffersOnlyTheCommandsThatApplyToIt() {
		func row(_ condition: DocumentCondition, contentKnown: Bool, sender: String?) -> DocumentRow {
			DocumentRow(
				document: DocumentIdentifier(value: "d1"),
				condition: condition,
				title: nil,
				senderName: sender,
				documentDate: nil,
				arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
				amount: nil,
				passage: nil,
				contentKnown: contentKnown,
				suggestedFileName: "document.pdf"
			)
		}
		#expect(DocumentRowCommand.groups(for: row(.archived, contentKnown: false, sender: "Nordbank AG")) == [
			[.openOriginal, .quickLook],
			[.share, .copy, .exportOriginal],
			[.moreFromSender(name: "Nordbank AG")],
			[.openInBrowser],
		])
		#expect(DocumentRowCommand.groups(for: row(
			.inIngestion(stage: .awaitingRendering),
			contentKnown: false,
			sender: nil
		)) == [[.openInBrowser]])
	}
}
