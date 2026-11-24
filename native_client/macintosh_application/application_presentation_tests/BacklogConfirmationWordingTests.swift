import ApplicationBindings
import ApplicationPresentation
import Testing

struct BacklogConfirmationWordingTests {
	private static func surveyedDownloads(
		filesNew: UInt64 = 930,
		newContents: UInt64 = 902,
		filesAlreadyArchived: UInt64 = 310,
		filesDeletedFromArchive: UInt64 = 0,
		filesRefusedByArchive: UInt64 = 0,
		skipped: [SkippedCount] = [
			SkippedCount(reason: .unrecognizedContent, count: 31),
			SkippedCount(reason: .emptyFile, count: 4),
			SkippedCount(reason: .incompleteDownload, count: 2),
			SkippedCount(reason: .hiddenEntry, count: 9),
			SkippedCount(reason: .appleDoubleCompanion, count: 3),
		],
		filesUnderExamination: UInt64 = 0
	) -> BacklogSummary {
		BacklogSummary(
			filesNew: filesNew,
			newContents: newContents,
			filesAlreadyArchived: filesAlreadyArchived,
			filesDeletedFromArchive: filesDeletedFromArchive,
			filesRefusedByArchive: filesRefusedByArchive,
			skipped: skipped,
			filesUnderExamination: filesUnderExamination
		)
	}

	@Test func saysWhatHappensToTheFilesThereAndThatEveryLaterFileUploadsWithoutAsking() {
		let wording = BacklogConfirmationWording.make(folderName: "Downloads", backlog: Self.surveyedDownloads())

		#expect(wording.heading == "Collect from Downloads?")
		#expect(wording.existingFilesHeading == "The files already there")
		#expect(wording.existingFiles == [
			"930 new files upload now. Identical copies upload once, so Schublade receives 902 distinct files.",
			"310 files are already in Schublade and stay as they are.",
		])
		#expect(wording.skippedSummary == "49 items are skipped:")
		#expect(wording.skippedGroups == [
			SkippedGroup(reason: "Not a PDF, JPEG, PNG, or WebP file", count: "31 files"),
			SkippedGroup(reason: "Hidden files and folders", count: "12 items"),
			SkippedGroup(reason: "Empty", count: "4 files"),
			SkippedGroup(reason: "Unfinished downloads", count: "2 items"),
		])
		#expect(wording.futureFilesHeading == "From now on")
		#expect(wording.futureFiles == "From now on, every new PDF, JPEG, PNG, or WebP file in Downloads uploads "
			+ "to Schublade automatically. You will not be asked again for this folder.")
		#expect(wording.uploadLabel == "Upload 930 Files and Start Collecting")
		#expect(wording.removeLabel == "Remove Folder")
		#expect(wording.examinationNote == nil)
	}

	@Test func countsSingleFilesInTheSingularAndNamesFilesDeletedOrRefusedEarlier() {
		let wording = BacklogConfirmationWording.make(folderName: "Scans", backlog: Self.surveyedDownloads(
			filesNew: 1,
			newContents: 1,
			filesAlreadyArchived: 1,
			filesDeletedFromArchive: 2,
			filesRefusedByArchive: 1,
			skipped: [SkippedCount(reason: .unreadable, count: 1)],
			filesUnderExamination: 3
		))

		#expect(wording.existingFiles == [
			"1 new file uploads now.",
			"1 file is already in Schublade and stays as it is.",
			"2 files were deleted from Schublade earlier and stay deleted.",
			"1 file was refused by Schublade earlier and is not sent again.",
		])
		#expect(wording.skippedSummary == "1 file is skipped:")
		#expect(wording.skippedGroups == [SkippedGroup(reason: "Could not be read", count: "1 file")])
		#expect(wording.examinationNote == "Still checking 3 files. The counts update as they finish.")
		#expect(wording.uploadLabel == "Upload 1 File and Start Collecting")
	}

	@Test func namesSymbolicLinksAndStartsCollectingWithoutAnUploadWhenNothingIsNew() {
		let wording = BacklogConfirmationWording.make(folderName: "Desktop", backlog: Self.surveyedDownloads(
			filesNew: 0,
			newContents: 0,
			skipped: [SkippedCount(reason: .symbolicLink, count: 2)]
		))

		#expect(wording.existingFiles.first == "Nothing new to upload now.")
		#expect(wording.skippedSummary == "2 items are skipped:")
		#expect(wording.skippedGroups == [SkippedGroup(reason: "Symbolic links", count: "2 items")])
		#expect(wording.uploadLabel == "Start Collecting")
	}
}
