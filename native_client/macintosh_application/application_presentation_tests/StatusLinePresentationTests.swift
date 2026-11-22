import ApplicationBindings
import ApplicationPresentation
import Foundation
import Testing

struct StatusLinePresentationTests {
	private static func fixedContext() -> WordingContext {
		var calendar = Calendar(identifier: .gregorian)
		if let universalTimeZone = TimeZone(secondsFromGMT: 0) {
			calendar.timeZone = universalTimeZone
		}
		return WordingContext(
			now: Date(timeIntervalSince1970: 1_790_000_000),
			calendar: calendar,
			locale: Locale(identifier: "en_GB"),
			folderName: { URL(fileURLWithPath: $0).lastPathComponent }
		)
	}

	private static func makeLibraryStatus(
		condition: ConnectionCondition = .connected,
		permission: ArchivePermission = .readAndCollect,
		copy: LibraryCopy = .complete(synchronizedAt: Date(timeIntervalSince1970: 1_790_000_000))
	) -> LibraryStatus {
		LibraryStatus(
			revision: 1,
			archive: .configured(
				origin: "https://archive.example.org",
				host: "archive.example.org",
				condition: condition,
				permission: permission,
				restricted: false
			),
			copy: copy,
			contentRevision: 1,
			counts: LibraryCounts(
				documents: 1508,
				documentsInIngestion: 0,
				documentsFailed: 0,
				documentsAwaitingText: 0
			)
		)
	}

	private static func makeCollectorStatus(
		awaitingSubmission: UInt64 = 0,
		admission: FolderAdmission = .collecting,
		activities: [Activity] = []
	) -> CollectorStatus {
		CollectorStatus(
			revision: 1,
			folders: [
				FolderStatus(
					folder: FolderReference(identifier: FolderIdentifier(value: 1), root: "/Users/owner/Downloads"),
					admission: admission,
					unavailability: nil
				),
			],
			progress: CollectionProgress(
				documentsInArchive: 10,
				documentsAwaitingSubmission: awaitingSubmission,
				filesUnderExamination: 0
			),
			activities: activities,
			attention: [],
			recentReceipts: []
		)
	}

	@Test func precedenceFavorsFaultAndRefusedTokenOverCopyAndUploads() {
		let context = Self.fixedContext()
		let faultStatus = ApplicationStatuses(
			library: Self.makeLibraryStatus(condition: .suspended(reason: .credentialRefused)),
			collector: Self.makeCollectorStatus(awaitingSubmission: 3),
			libraryFault: .StoreFailed(detail: "disk full"),
			collectorFault: nil
		)
		let faultLine = StatusLinePresentation.resolve(statuses: faultStatus, context: context)
		#expect(faultLine.tone == .attention)
		#expect(faultLine.text == "Local storage error: disk full")

		let refusedStatus = ApplicationStatuses(
			library: Self.makeLibraryStatus(
				condition: .suspended(reason: .credentialRefused),
				copy: .filling(received: 500, remaining: 1008)
			),
			collector: Self.makeCollectorStatus(awaitingSubmission: 2)
		)
		let refusedLine = StatusLinePresentation.resolve(statuses: refusedStatus, context: context)
		#expect(refusedLine.text == "Token refused")
		#expect(refusedLine.tone == .attention)
		#expect(refusedLine.allowsTokenReplacement)
		#expect(!refusedLine.allowsSynchronize)
	}

	@Test func offlineShowsLastCompleteTimeAndLoadingReportsProgressFraction() throws {
		let context = Self.fixedContext()
		var calendar = Calendar(identifier: .gregorian)
		if let universalTimeZone = TimeZone(secondsFromGMT: 0) {
			calendar.timeZone = universalTimeZone
		}
		let syncMoment = try #require(
			calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 13, minute: 40))
		)

		let offlineStatus = ApplicationStatuses(
			library: Self.makeLibraryStatus(
				condition: .unreachable(since: syncMoment, nextAttemptAt: syncMoment.addingTimeInterval(60)),
				copy: .complete(synchronizedAt: syncMoment)
			)
		)
		let offlineLine = StatusLinePresentation.resolve(statuses: offlineStatus, context: context)
		#expect(offlineLine.text == "Offline · updated 13:40")
		#expect(offlineLine.allowsSynchronize)

		let fillingStatus = ApplicationStatuses(
			library: Self.makeLibraryStatus(copy: .filling(received: 500, remaining: 1008))
		)
		let fillingLine = StatusLinePresentation.resolve(statuses: fillingStatus, context: context)
		#expect(fillingLine.text == "Loading · 500 of 1,508")
		#expect(fillingLine.tone == .active)
		let progress = try #require(fillingLine.progress)
		#expect(abs(progress - (500.0 / 1508.0)) < 0.0001)
	}

	@Test func uploadingPrecedesUpToDateAndSkipsUnconfirmedBacklog() throws {
		let context = Self.fixedContext()
		var calendar = Calendar(identifier: .gregorian)
		if let universalTimeZone = TimeZone(secondsFromGMT: 0) {
			calendar.timeZone = universalTimeZone
		}
		let syncMoment = try #require(
			calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 14, minute: 2))
		)

		let uploadingStatus = ApplicationStatuses(
			library: Self.makeLibraryStatus(copy: .complete(synchronizedAt: syncMoment)),
			collector: Self.makeCollectorStatus(awaitingSubmission: 2, admission: .collecting)
		)
		let uploadingLine = StatusLinePresentation.resolve(statuses: uploadingStatus, context: context)
		#expect(uploadingLine.text == "Uploading 2 files")
		#expect(uploadingLine.tone == .active)

		let unconfirmedBacklog = BacklogSummary(
			filesNew: 4,
			newContents: 4,
			filesAlreadyArchived: 0,
			filesDeletedFromArchive: 0,
			filesRefusedByArchive: 0,
			skipped: [],
			filesUnderExamination: 0
		)
		let settledStatus = ApplicationStatuses(
			library: Self.makeLibraryStatus(copy: .complete(synchronizedAt: syncMoment)),
			collector: Self.makeCollectorStatus(
				awaitingSubmission: 4,
				admission: .awaitingDecision(backlog: unconfirmedBacklog)
			)
		)
		let settledLine = StatusLinePresentation.resolve(statuses: settledStatus, context: context)
		#expect(settledLine.text == "Up to date · 14:02")
		#expect(settledLine.tone == .normal)
	}
}
