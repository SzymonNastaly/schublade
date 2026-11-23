import ApplicationBindings
import ApplicationPresentation
import Foundation
import LibraryPresentation
import Testing

struct WindowContentAndSidebarTests {
	static func fixedContext() -> ApplicationWordingContext {
		var calendar = Calendar(identifier: .gregorian)
		if let universalTimeZone = TimeZone(secondsFromGMT: 0) {
			calendar.timeZone = universalTimeZone
		}
		return ApplicationWordingContext(
			library: WordingContext(
				now: Date(timeIntervalSince1970: 1_790_000_000),
				calendar: calendar,
				locale: Locale(identifier: "en_GB")
			),
			folderName: { root in
				root.hasSuffix("/Documents") ? "Dokumente" : URL(fileURLWithPath: root).lastPathComponent
			}
		)
	}

	static func makeFacets(
		inIngestion: UInt64 = 0,
		failed: UInt64 = 0
	) -> LibraryFacets {
		LibraryFacets(
			contentRevision: 3,
			documents: 1508,
			documentsInIngestion: inIngestion,
			documentsFailed: failed,
			householdDocuments: 611,
			members: [
				ScopeCount(
					scope: NamedScope(
						scope: .member(member: MemberIdentifier(value: "m1")),
						name: "Jonas Becker"
					),
					documents: 402
				),
			],
			categories: [
				ScopeCount(
					scope: NamedScope(
						scope: .category(category: CategoryIdentifier(value: "c1")),
						name: "Invoice"
					),
					documents: 412
				),
				ScopeCount(
					scope: NamedScope(
						scope: .category(category: CategoryIdentifier(value: "c2")),
						name: "Empty Category"
					),
					documents: 0
				),
			],
			tags: [
				ScopeCount(
					scope: NamedScope(
						scope: .tag(tag: TagIdentifier(value: "t1")),
						name: "strom"
					),
					documents: 38
				),
			]
		)
	}

	static func makeStatuses(
		condition: ConnectionCondition = .connected,
		permission: ArchivePermission = .readAndCollect,
		awaitingText: UInt64 = 0,
		documents: UInt64 = 1508,
		collectorAttention: [AttentionItem] = []
	) -> ApplicationStatuses {
		let library = LibraryStatus(
			revision: 1,
			archive: .configured(
				origin: "https://archive.example.org",
				host: "archive.example.org",
				condition: condition,
				permission: permission,
				restricted: false
			),
			copy: .complete(synchronizedAt: Date(timeIntervalSince1970: 1_790_000_000)),
			contentRevision: 3,
			counts: LibraryCounts(
				documents: documents,
				documentsInIngestion: 2,
				documentsFailed: 0,
				documentsAwaitingText: awaitingText
			)
		)
		let collector = CollectorStatus(
			revision: 1,
			folders: [
				FolderStatus(
					folder: FolderReference(identifier: FolderIdentifier(value: 1), root: "/Users/owner/Documents"),
					admission: .collecting,
					unavailability: nil
				),
			],
			progress: CollectionProgress(
				documentsInArchive: 0,
				documentsAwaitingSubmission: 0,
				filesUnderExamination: 0
			),
			activities: [],
			attention: collectorAttention,
			recentReceipts: []
		)
		return ApplicationStatuses(library: library, collector: collector)
	}

	@Test func outdatedArchiveStaysInWorkspaceAndSearchFooterReportsIndexingProgress() {
		let context = Self.fixedContext()
		let facets = Self.makeFacets(inIngestion: 2, failed: 1)

		let outdated = WindowContent.resolve(
			situation: .running(Self.makeStatuses(condition: .archiveOutdated)),
			navigation: LibraryNavigationState(),
			facets: facets,
			context: context
		)
		guard case let .libraryWorkspace(outdatedWorkspace) = outdated else {
			Issue.record("Expected library workspace for outdated archive")
			return
		}
		#expect(outdatedWorkspace.detailMode == .archiveOutdated(message: "Update your archive to use the library."))

		var categoryNavigation = LibraryNavigationState(
			destination: .library(.category(category: CategoryIdentifier(value: "c1")), title: "Invoice"),
			searchText: "versicherung",
			browseOrder: .sender
		)
		#expect(categoryNavigation.activeListingRequest == .search(
			scope: .category(category: CategoryIdentifier(value: "c1")),
			text: "versicherung"
		))

		let searchContent = WindowContent.resolve(
			situation: .running(Self.makeStatuses(awaitingText: 308)),
			navigation: categoryNavigation,
			facets: facets,
			context: context
		)
		guard case let .libraryWorkspace(searchWorkspace) = searchContent else {
			Issue.record("Expected library workspace")
			return
		}
		#expect(searchWorkspace.searchAllDocumentsAvailable)
		#expect(searchWorkspace.textIndexingNotice == "Searching the text of 1,200 of 1,508 documents")
		#expect(!searchWorkspace.allowsSortSelection)
		#expect(searchWorkspace.windowTitle == "Invoice")

		categoryNavigation.searchText = ""
		categoryNavigation.destination = .library(.recentlyAdded, title: nil)
		#expect(categoryNavigation.activeListingRequest == .browse(scope: .recentlyAdded, order: .addition))
	}

	@Test func sidebarFiltersEmptyTaxonomiesAndFormatsLocalizedFolderNames() throws {
		let context = Self.fixedContext()
		let statuses = Self.makeStatuses(
			condition: .suspended(reason: .credentialRefused),
			collectorAttention: [.credentialSuspended(reason: .credentialRefused)]
		)
		let facets = Self.makeFacets(inIngestion: 2, failed: 1)
		let sidebar = SidebarPresentation.resolve(statuses: statuses, facets: facets, context: context)

		let libraryItems = try #require(sidebar.sections.first { $0.id == "library" }?.items)
		#expect(libraryItems.map(\.title) == ["All Documents", "Recently Added", "Arriving", "Needs Attention"])
		let attentionItem = try #require(libraryItems.first { $0.id == "library.needsAttention" })
		#expect(attentionItem.accessory == .count("2"))

		let categoryItems = try #require(sidebar.sections.first { $0.id == "categories" }?.items)
		#expect(categoryItems.map(\.title) == ["Invoice"])

		let folderItems = try #require(sidebar.sections.first { $0.id == "folders" }?.items)
		#expect(folderItems.map(\.title) == ["Dokumente", "Add Folder…"])
	}

	@Test func aSearchTypedOnAPageMovesToAllDocuments() {
		var navigation = LibraryNavigationState(destination: .folder(FolderIdentifier(value: 2)))
		navigation.search("  ")
		#expect(navigation.destination == .folder(FolderIdentifier(value: 2)))
		navigation.search("Nordbank")
		#expect(navigation.destination == .library(.allDocuments, title: nil))
		#expect(navigation.searchText == "Nordbank")
	}

	@Test func emptyListAndTokenReplacementTransitions() {
		let statuses = Self.makeStatuses(condition: .suspended(reason: .credentialRefused))
		var navigation = LibraryNavigationState()
		navigation.replacingTokenOrigin = "https://archive.example.org"
		let replacing = WindowContent.resolve(
			situation: .running(statuses),
			navigation: navigation,
			facets: nil,
			context: Self.fixedContext()
		)
		guard case let .connectionForm(address, _, cancellable) = replacing else {
			Issue.record("Expected cancellable connection form while replacing token")
			return
		}
		#expect(address == "https://archive.example.org")
		#expect(cancellable)

		var arriving = LibraryNavigationState()
		arriving.destination = .library(.inIngestion, title: nil)
		let emptyScope = EmptyStatePresentation.list(
			navigation: arriving,
			libraryStatus: statuses.library,
			libraryFault: nil,
			listingFault: nil,
			hasCollector: true
		)
		#expect(emptyScope == EmptyStatePresentation(
			picture: .symbol("tray"),
			title: "Nothing Arriving",
			detail: "Documents appear here while the archive reads them.",
			action: nil
		))
	}
}
