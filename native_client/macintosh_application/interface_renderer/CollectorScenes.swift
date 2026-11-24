import ApplicationBindings
import ApplicationPresentation
import Foundation

/// The collector's pages as `InterfaceRenderer` draws them: a folder being surveyed, a folder
/// awaiting its decision, a folder collecting with its latest uploads, a folder Schublade may not
/// read, the library while the archive refuses the token, and Needs Attention.
enum CollectorScenes {
	struct Scene {
		let name: String
		let statuses: ApplicationStatuses
		let facets: LibraryFacets
		let navigation: LibraryNavigationState
	}

	static func all(fixtures: RendererFixtures) -> [Scene] {
		let paperwork = NavigationDestination.folder(RendererFixtures.paperwork.identifier)
		let downloads = NavigationDestination.folder(RendererFixtures.downloads.identifier)
		var facetsWithFailures = RendererSampleCatalog.sampleFacets
		facetsWithFailures.documentsFailed = 2
		let attention: [AttentionItem] = [
			.backlogAwaitsDecision(folder: RendererFixtures.paperwork),
			.folderUnavailable(
				folder: FolderReference(identifier: FolderIdentifier(value: 3), root: "/Volumes/Archive/Scans"),
				unavailability: .missing
			),
			.contentRefused(fileName: "Scan 2026-11-03.tiff", reason: .unacceptedKind),
		]
		return [
			scene("folder_surveying", fixtures, paperwork, RendererFixtures.makeCollectorStatus(
				paperworkAdmission: .surveying(filesUnderExamination: 37)
			)),
			scene("folder_confirmation", fixtures, paperwork, RendererFixtures.makeCollectorStatus(
				paperworkAdmission: .awaitingDecision(backlog: backlog),
				attention: [.backlogAwaitsDecision(folder: RendererFixtures.paperwork)]
			)),
			scene("folder_collecting", fixtures, downloads, RendererFixtures.makeCollectorStatus(receipts: receipts)),
			scene("folder_unreadable", fixtures, paperwork, RendererFixtures.makeCollectorStatus(
				paperworkUnavailability: .accessDenied,
				attention: [.folderUnavailable(folder: RendererFixtures.paperwork, unavailability: .accessDenied)]
			)),
			Scene(
				name: "library_token_refused",
				statuses: fixtures.makeStatuses(
					condition: .suspended(reason: .credentialRefused),
					collector: RendererFixtures.makeCollectorStatus(
						attention: [.credentialSuspended(reason: .credentialRefused)]
					)
				),
				facets: RendererSampleCatalog.sampleFacets,
				navigation: LibraryNavigationState(
					destination: .library(.allDocuments, title: nil),
					selectedDocument: fixtures.invoiceIdentifier
				)
			),
			scene(
				"needs_attention",
				fixtures,
				.needsAttention,
				RendererFixtures.makeCollectorStatus(
					paperworkAdmission: .awaitingDecision(backlog: backlog),
					attention: attention
				),
				facets: facetsWithFailures
			),
		]
	}

	private static func scene(
		_ name: String,
		_ fixtures: RendererFixtures,
		_ destination: NavigationDestination,
		_ collector: CollectorStatus,
		facets: LibraryFacets = RendererSampleCatalog.sampleFacets
	) -> Scene {
		Scene(
			name: name,
			statuses: fixtures.makeStatuses(collector: collector, facets: facets),
			facets: facets,
			navigation: LibraryNavigationState(destination: destination)
		)
	}

	private static let backlog = BacklogSummary(
		filesNew: 48,
		newContents: 45,
		filesAlreadyArchived: 12,
		filesDeletedFromArchive: 1,
		filesRefusedByArchive: 0,
		skipped: [
			SkippedCount(reason: .unrecognizedContent, count: 9),
			SkippedCount(reason: .cloudPlaceholder, count: 3),
			SkippedCount(reason: .incompleteDownload, count: 2),
		],
		filesUnderExamination: 0
	)

	private static let receipts = [
		receipt("Meldebescheinigung.pdf", minutesAgo: 4, outcome: .processing),
		receipt("Kontoauszug Oktober 2026.pdf", minutesAgo: 52, outcome: .archived),
		receipt("Beleg Baumarkt.jpg", minutesAgo: 1460, outcome: .archived),
		receipt("Scan 0042.pdf", minutesAgo: 2900, outcome: .failed),
	]

	private static func receipt(_ name: String, minutesAgo: Double, outcome: DocumentOutcome) -> Receipt {
		let identifier = "50000000-0000-4000-8000-0000000000\(name.count)"
		return Receipt(
			documentIdentifier: identifier,
			documentLink: "https://archive.example.org/documents/\(identifier)",
			fileName: name,
			receivedAt: Date(timeIntervalSince1970: 1_790_000_000 - minutesAgo * 60),
			outcome: outcome
		)
	}
}
