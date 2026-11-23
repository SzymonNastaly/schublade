import ApplicationBindings
import ApplicationPresentation
import Foundation
import LibraryPresentation
import Testing

struct CollectorWordingTests {
	private static let downloads = FolderReference(
		identifier: FolderIdentifier(value: 1),
		root: "/Users/jonas/Downloads"
	)
	private static let scans = FolderReference(
		identifier: FolderIdentifier(value: 2),
		root: "/Volumes/Archive Disk/Scans/"
	)
	private static let connected = ArchiveConnection.configured(
		origin: "https://archive.example.org",
		host: "archive.example.org",
		condition: .connected,
		permission: .readAndCollect,
		restricted: false
	)

	private static func fixedContext() -> ApplicationWordingContext {
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
			folderName: { URL(fileURLWithPath: $0).lastPathComponent }
		)
	}

	private static func makeStatus(
		folders: [FolderStatus],
		awaitingSubmission: UInt64 = 0,
		underExamination: UInt64 = 0
	) -> CollectorStatus {
		CollectorStatus(
			revision: 7,
			folders: folders,
			progress: CollectionProgress(
				documentsInArchive: 0,
				documentsAwaitingSubmission: awaitingSubmission,
				filesUnderExamination: underExamination
			),
			activities: [],
			attention: [],
			recentReceipts: []
		)
	}

	private static let collectingDownloads = FolderStatus(
		folder: downloads,
		admission: .collecting,
		unavailability: nil
	)
	private static let missingScans = FolderStatus(
		folder: scans,
		admission: .surveying(filesUnderExamination: 4),
		unavailability: .missing
	)

	@Test func attentionNamesEachItemWithTheFolderNameAndItsControl() {
		let items: [AttentionItem] = [
			.credentialSuspended(reason: .credentialRefused),
			.folderUnavailable(folder: Self.scans, unavailability: .missing),
			.backlogAwaitsDecision(folder: Self.downloads),
			.contentRefused(fileName: "Holiday video.pdf", reason: .tooLarge),
			.contentFailing(fileName: "Invoice.pdf", failures: 4),
		]
		let sentences = items.map { CollectorWording.attentionSentence($0, context: Self.fixedContext()) }
		#expect(sentences == [
			AttentionSentence(
				text: "Schublade refused the token, so nothing uploads. "
					+ "Issue a new API token in Schublade's Settings and paste it here.",
				tone: .failure,
				action: .replaceToken
			),
			AttentionSentence(
				text: "Scans is missing. It may have been moved, renamed, or be on a disconnected drive. "
					+ "Collecting resumes when it is back.",
				tone: .failure,
				action: .openFolder(FolderIdentifier(value: 2))
			),
			AttentionSentence(
				text: "Downloads waits for your decision.",
				tone: .attention,
				action: .decideBacklog(FolderIdentifier(value: 1))
			),
			AttentionSentence(
				text: "Schublade refused Holiday video.pdf, because it is larger than the archive accepts.",
				tone: .failure,
				action: nil
			),
			AttentionSentence(
				text: "Invoice.pdf failed to upload 4 times. The collector keeps trying.",
				tone: .attention,
				action: nil
			),
		])
	}

	@Test func folderStateReadsAvailabilityBeforeAdmission() {
		let surveying = FolderStatus(
			folder: Self.scans,
			admission: .surveying(filesUnderExamination: 4),
			unavailability: nil
		)
		#expect(CollectorWording.folderState(Self.collectingDownloads).label == "Collecting")
		#expect(CollectorWording.folderState(Self.missingScans) == FolderStatePresentation(
			label: "Missing",
			tone: .failure,
			detail: "The folder is not there. Collecting resumes when it is back."
		))
		#expect(CollectorWording.folderState(surveying) == FolderStatePresentation(
			label: "Surveying",
			tone: .processing,
			detail: "Checking 4 files. Nothing uploads before you decide."
		))
	}

	@Test func restingSaysEverythingIsCollectedOnlyWhileNothingWaitsAndTheArchiveAnswers() {
		let folders = [Self.collectingDownloads, Self.missingScans]
		let paused = ArchiveConnection.configured(
			origin: "https://archive.example.org",
			host: "archive.example.org",
			condition: .suspended(reason: .credentialRefused),
			permission: .readAndCollect,
			restricted: false
		)
		let resting = { (status: CollectorStatus, connection: ArchiveConnection?) in
			CollectorWording.restingSentence(status, connection: connection)
		}
		#expect(resting(Self.makeStatus(folders: folders), Self.connected)
			== "Everything is collected. Watching 2 folders for new files.")
		#expect(resting(Self.makeStatus(folders: folders), paused) == "Watching 2 folders for new files.")
		#expect(resting(Self.makeStatus(folders: folders, awaitingSubmission: 3), Self.connected)
			== "Watching 2 folders for new files.")
		#expect(resting(Self.makeStatus(folders: folders, underExamination: 1), Self.connected)
			== "Watching 2 folders for new files.")
		#expect(resting(Self.makeStatus(folders: []), Self.connected) == "Add a folder to start collecting.")
	}

	@Test func connectionSaysWhyItIsPausedAndWhenItTriesAgain() {
		let context = Self.fixedContext()
		let connection = { (condition: ConnectionCondition) in
			ArchiveConnection.configured(
				origin: "https://archive.example.org",
				host: "archive.example.org",
				condition: condition,
				permission: .collectOnly,
				restricted: false
			)
		}
		#expect(CollectorWording.connectionSentence(
			connection(.suspended(reason: .credentialRefused)),
			context: context
		) == "Paused, because Schublade refused the token.")
		let unreachable = ConnectionCondition.unreachable(
			since: Date(timeIntervalSince1970: 1_789_999_340),
			nextAttemptAt: Date(timeIntervalSince1970: 1_789_999_640)
		)
		#expect(CollectorWording.connectionSentence(connection(unreachable), context: context)
			== "The archive has not answered since 14:02. The next attempt is at 14:07.")
	}

	@Test func activityNamesTheFolderTheFileAndItsSize() {
		let context = Self.fixedContext()
		let activities: [Activity] = [
			.listing(folder: Self.downloads, directory: ""),
			.listing(folder: Self.downloads, directory: "Bank/2026"),
			.lookingUp(contentCount: 1),
			.submitting(fileName: "Invoice.pdf", byteSize: 253_289),
		]
		#expect(activities.map { CollectorWording.activitySentence($0, context: context) } == [
			"Looking through Downloads",
			"Looking through Downloads/Bank/2026",
			"Asking Schublade about 1 file",
			"Uploading Invoice.pdf (253.3 KB)",
		])
	}

	@Test func progressShowsTheArchivedCountAndOnlyTheOtherCountsAboveZero() {
		let resting = CollectionProgress(
			documentsInArchive: 1,
			documentsAwaitingSubmission: 0,
			filesUnderExamination: 0
		)
		let busy = CollectionProgress(
			documentsInArchive: 1240,
			documentsAwaitingSubmission: 3,
			filesUnderExamination: 12
		)
		#expect(CollectorWording.progressSentences(resting) == ["1 document in Schublade"])
		#expect(CollectorWording.progressSentences(busy) == [
			"1,240 documents in Schublade",
			"3 files waiting to upload",
			"12 files being checked",
		])
	}

	@Test func receiptShowsTodayByItsClockTimeAndAnEarlierDayByItsDate() {
		let context = Self.fixedContext()
		#expect(CollectorWording.receiptTime(Date(timeIntervalSince1970: 1_789_999_340), context: context)
			== "Today, 14:02")
		#expect(CollectorWording.receiptTime(Date(timeIntervalSince1970: 1_786_526_100), context: context)
			== "12 Aug, 9:15")
		#expect(CollectorWording.receiptOutcome(.failed) == ReceiptOutcomePresentation(label: "Failed", tone: .failure))
	}

	@Test func folderCommandRefusalsNameTheFolder() {
		let context = Self.fixedContext()
		#expect(CollectorRefusalWording.enrollmentRefusalSentence(
			.OverlapsEnrolledFolder(folder: Self.downloads),
			context: context
		) == "This folder is inside Downloads or contains it. Each file can be collected from one folder only.")
		#expect(CollectorRefusalWording.decisionRefusalSentence(.SurveyIncomplete(folder: Self.scans), context: context)
			== "Scans is still being surveyed.")
	}
}
