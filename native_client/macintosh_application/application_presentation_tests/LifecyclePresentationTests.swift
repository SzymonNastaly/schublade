import ApplicationBindings
import ApplicationPresentation
import Foundation
import Testing

struct LifecyclePresentationTests {
	private static func running(configured: Bool, folders: Int = 0) -> ApplicationSituation {
		let archive: ArchiveConnection = configured
			? .configured(
				origin: "https://archive.example.org",
				host: "archive.example.org",
				condition: .connected,
				permission: .readAndCollect,
				restricted: false
			)
			: .notConfigured
		let folderStatuses = (0 ..< folders).map { index in
			FolderStatus(
				folder: FolderReference(
					identifier: FolderIdentifier(value: Int64(index)),
					root: "/Users/owner/\(index)"
				),
				admission: .collecting,
				unavailability: nil
			)
		}
		return .running(ApplicationStatuses(
			library: LibraryStatus(
				revision: 1,
				archive: archive,
				copy: .complete(synchronizedAt: Date(timeIntervalSince1970: 1_790_000_000)),
				contentRevision: 1,
				counts: LibraryCounts(
					documents: 0,
					documentsInIngestion: 0,
					documentsFailed: 0,
					documentsAwaitingText: 0
				)
			),
			collector: CollectorStatus(
				revision: 1,
				folders: folderStatuses,
				progress: CollectionProgress(
					documentsInArchive: 0,
					documentsAwaitingSubmission: 0,
					filesUnderExamination: 0
				),
				activities: [],
				attention: [],
				recentReceipts: []
			)
		))
	}

	@Test func aLoginLaunchOpensTheWindowOnlyWhenSomethingNeedsAPerson() {
		#expect(LifecyclePresentation.launchWindow(origin: .person, situation: .starting) == .opens)
		#expect(LifecyclePresentation.launchWindow(origin: .loginItem, situation: .starting) == .undecided)
		#expect(LifecyclePresentation.launchWindow(origin: .loginItem, situation: .stopped) == .opens)
		#expect(LifecyclePresentation.launchWindow(
			origin: .loginItem,
			situation: Self.running(configured: false)
		) == .opens)
		#expect(LifecyclePresentation.launchWindow(
			origin: .loginItem,
			situation: Self.running(configured: true)
		) == .staysClosed)
	}

	@Test func quittingAsksOnlyWhileFoldersAreCollectedAndTheLoginItemIsRegisteredOnce() {
		#expect(!LifecyclePresentation.asksBeforeQuitting(situation: Self.running(configured: true), suppressed: false))
		#expect(LifecyclePresentation.asksBeforeQuitting(
			situation: Self.running(configured: true, folders: 1),
			suppressed: false
		))
		#expect(!LifecyclePresentation.asksBeforeQuitting(
			situation: Self.running(configured: true, folders: 1),
			suppressed: true
		))
		#expect(LifecyclePresentation.registersLoginItem(
			situation: Self.running(configured: true),
			alreadyEstablished: false
		))
		#expect(!LifecyclePresentation.registersLoginItem(
			situation: Self.running(configured: true),
			alreadyEstablished: true
		))
		#expect(!LifecyclePresentation.registersLoginItem(
			situation: Self.running(configured: false),
			alreadyEstablished: false
		))
	}
}

struct StorageWordingTests {
	@Test func limitsAndTheRoomTakenReadAsPeopleExpect() {
		#expect(StorageWording.limitChoices.map(StorageWording.limitTitle).last == "No Limit")
		#expect(StorageWording.limitChoices[1] == 2_000_000_000)
		#expect(StorageWording.heldSentence(0) == "No originals are downloaded on this Mac.")
		#expect(StorageWording.heldSentence(412_000_000).hasPrefix("Downloaded originals take 412"))
	}
}
