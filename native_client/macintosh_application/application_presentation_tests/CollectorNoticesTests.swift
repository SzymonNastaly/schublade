import ApplicationBindings
import ApplicationPresentation
import Foundation
import Testing

struct CollectorNoticesTests {
	private static let downloads = FolderReference(
		identifier: FolderIdentifier(value: 1),
		root: "/Users/owner/Downloads"
	)

	private static func context() -> WordingContext {
		WordingContext(
			now: Date(timeIntervalSince1970: 1_790_000_000),
			calendar: Calendar(identifier: .gregorian),
			locale: Locale(identifier: "en_GB"),
			folderName: { URL(fileURLWithPath: $0).lastPathComponent }
		)
	}

	private static func status(_ admission: FolderAdmission, attention: [AttentionItem] = []) -> CollectorStatus {
		CollectorStatus(
			revision: 1,
			folders: [FolderStatus(folder: downloads, admission: admission, unavailability: nil)],
			progress: CollectionProgress(
				documentsInArchive: 0,
				documentsAwaitingSubmission: 0,
				filesUnderExamination: 0
			),
			activities: [],
			attention: attention,
			recentReceipts: []
		)
	}

	private static let awaiting = FolderAdmission.awaitingDecision(backlog: BacklogSummary(
		filesNew: 3,
		newContents: 3,
		filesAlreadyArchived: 0,
		filesDeletedFromArchive: 0,
		filesRefusedByArchive: 0,
		skipped: [],
		filesUnderExamination: 0
	))

	@Test func aFinishedSurveyAndANewlyRefusedTokenEachNotifyOnce() {
		let surveying = Self.status(.surveying(filesUnderExamination: 4))
		let decided = CollectorNotices.arising(
			previous: surveying,
			next: Self.status(Self.awaiting),
			context: Self.context()
		)
		#expect(decided.map(\.title) == ["Downloads is ready for your decision"])
		#expect(decided.map(\.action) == [.decideBacklog(FolderIdentifier(value: 1))])

		let refused = Self.status(.collecting, attention: [.credentialSuspended(reason: .credentialRefused)])
		let tokenNotices = CollectorNotices.arising(
			previous: Self.status(.collecting),
			next: refused,
			context: Self.context()
		)
		#expect(tokenNotices.map(\.action) == [.replaceToken])
		#expect(CollectorNotices.arising(previous: refused, next: refused, context: Self.context()).isEmpty)
	}

	@Test func theFirstStatusAfterLaunchNotifiesNothing() {
		let waiting = Self.status(Self.awaiting, attention: [.credentialSuspended(reason: .credentialRefused)])
		#expect(CollectorNotices.arising(previous: nil, next: waiting, context: Self.context()).isEmpty)
	}
}
