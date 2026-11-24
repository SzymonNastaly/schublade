import ApplicationBindings
import ApplicationPresentation
import Foundation
import LibraryPresentation
import Testing

struct StatusItemPresentationTests {
	private static let paperwork = FolderReference(
		identifier: FolderIdentifier(value: 2),
		root: "/Users/owner/Paperwork"
	)

	private static func context() -> ApplicationWordingContext {
		ApplicationWordingContext(
			library: WordingContext(
				now: Date(timeIntervalSince1970: 1_790_000_000),
				calendar: Calendar(identifier: .gregorian),
				locale: Locale(identifier: "en_GB")
			),
			folderName: { URL(fileURLWithPath: $0).lastPathComponent }
		)
	}

	private static func statuses(
		condition: ConnectionCondition = .connected,
		activities: [Activity] = [],
		attention: [AttentionItem] = []
	) -> ApplicationStatuses {
		ApplicationStatuses(
			library: LibraryStatus(
				revision: 1,
				archive: .configured(
					origin: "https://archive.example.org",
					host: "archive.example.org",
					condition: condition,
					permission: .readAndCollect,
					restricted: false
				),
				copy: .complete(synchronizedAt: Date(timeIntervalSince1970: 1_790_000_000)),
				contentRevision: 1,
				counts: LibraryCounts(
					documents: 9,
					documentsInIngestion: 0,
					documentsFailed: 3,
					documentsAwaitingText: 0
				)
			),
			collector: CollectorStatus(
				revision: 1,
				folders: [],
				progress: CollectionProgress(
					documentsInArchive: 9,
					documentsAwaitingSubmission: 0,
					filesUnderExamination: 0
				),
				activities: activities,
				attention: attention,
				recentReceipts: []
			)
		)
	}

	private static func glyph(_ statuses: ApplicationStatuses) -> StatusItemGlyph {
		StatusItemPresentation.resolve(situation: .running(statuses), context: context()).glyph
	}

	@Test func glyphFollowsThePrecedenceAndSpeaksOnlyForThisMac() {
		let uploading: [Activity] = [.submitting(fileName: "Tax assessment 2025.pdf", byteSize: 120_000)]
		#expect(Self.glyph(Self.statuses()) == .resting)
		#expect(Self.glyph(Self.statuses(activities: uploading)) == .submitting)
		#expect(Self.glyph(Self.statuses(condition: .checking, activities: uploading)) == .archiveUnreachable)
		#expect(Self.glyph(Self.statuses(
			condition: .checking,
			attention: [.backlogAwaitsDecision(folder: Self.paperwork)]
		)) == .attentionRequired)
		#expect(Self.glyph(Self.statuses(
			attention: [.contentRefused(fileName: "Scan.tiff", reason: .unacceptedKind)]
		)) == .resting)
		#expect(Self.glyph(Self.statuses(condition: .suspended(reason: .credentialRefused))) == .attentionRequired)

		let presentation = StatusItemPresentation.resolve(
			situation: .running(Self.statuses(activities: uploading)),
			context: Self.context()
		)
		#expect(presentation.uploadSentence == "Uploading Tax assessment 2025.pdf")
		#expect(StatusItemPresentation.resolve(situation: .starting, context: Self.context()).glyph == .starting)
	}

	@Test func theMenuSaysTheUploadOnceAndNamesEachNewDocumentsSender() {
		let uploading: [Activity] = [
			.submitting(fileName: "Tax assessment 2025.pdf", byteSize: 120_000),
			.submitting(fileName: "Invoice.pdf", byteSize: 80000),
		]
		let busy = StatusItemPresentation.resolve(
			situation: .running(Self.statuses(activities: uploading)),
			context: Self.context()
		)
		#expect(busy.statusSentence.hasPrefix("Up to date · "))
		#expect(busy.uploadSentence == "Uploading 2 files")

		var row = DocumentRow(
			document: DocumentIdentifier(value: "doc-electricity"),
			condition: .archived,
			title: "Electricity Annual Statement 2026",
			senderName: "Stadtwerke Talbrück GmbH",
			documentDate: CalendarDate(year: 2026, month: 9, day: 22),
			arrivedAt: Date(timeIntervalSince1970: 1_790_000_000),
			amount: nil,
			passage: nil,
			contentKnown: true,
			suggestedFileName: "document.pdf"
		)
		#expect(StatusItemPresentation.documentSubtitle(row, context: Self.context())
			== "Stadtwerke Talbrück GmbH · 22 Sep")
		row.senderName = nil
		#expect(StatusItemPresentation.documentSubtitle(row, context: Self.context()) == "22 Sep")
		row.documentDate = nil
		#expect(StatusItemPresentation.documentSubtitle(row, context: Self.context()) == nil)
	}

	@Test func anUploadFinishesTheCycleItBeganAndReduceMotionHoldsOneFrame() {
		var animation = StatusItemAnimation()
		animation.follow(.submitting, reduceMotion: false)
		#expect(animation.frame == 0)
		for _ in 1 ..< StatusItemAnimation.frameCount {
			animation.tick(stillSubmitting: false)
		}
		#expect(animation.frame == StatusItemAnimation.frameCount - 1)
		animation.tick(stillSubmitting: false)
		#expect(animation.frame == nil)
		#expect(!animation.needsTimer)

		animation.follow(.submitting, reduceMotion: false)
		animation.follow(.attentionRequired, reduceMotion: false)
		#expect(animation.frame == nil)

		var reduced = StatusItemAnimation()
		reduced.follow(.submitting, reduceMotion: true)
		#expect(!reduced.needsTimer)
		#expect(reduced.frame(for: .submitting, reduceMotion: true) == StatusItemAnimation.stillFrame)
	}
}
