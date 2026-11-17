import { describe, expect, it } from "vitest"
import { backlogConfirmationWording } from "./backlog_confirmation_wording"
import type { BacklogSummary } from "./collector_status"

const surveyedDownloads: BacklogSummary = {
	folders: [1],
	candidate_files: 1240,
	files_already_archived: 310,
	files_deleted_from_archive: 0,
	files_refused_by_archive: 0,
	files_new: 930,
	new_contents: 902,
	excluded_files: 35,
	excluded_files_by_reason: { UnrecognizedContent: 31, EmptyFile: 4 },
	disregarded_files: { IncompleteDownload: 2, HiddenEntry: 9, AppleDoubleCompanion: 3 },
	unreadable_files: 0,
	files_under_examination: 0,
}

describe("the backlog confirmation", () => {
	it("says what happens to the files already there and that every later file uploads without asking", () => {
		const wording = backlogConfirmationWording("Downloads", surveyedDownloads)

		expect(wording.heading).toBe("Collect from Downloads?")
		expect(wording.existingFiles).toEqual([
			"930 new files upload now. Identical copies upload once, so Schublade receives 902 distinct files.",
			"310 files are already in Schublade and stay as they are.",
		])
		expect(wording.skippedSummary).toBe("49 items are skipped:")
		expect(wording.skippedGroups).toEqual([
			{ reason: "Not a PDF, JPEG, PNG, or WebP file", count: "31 files" },
			{ reason: "Hidden files and folders", count: "12 items" },
			{ reason: "Empty", count: "4 files" },
			{ reason: "Unfinished downloads", count: "2 items" },
		])
		expect(wording.futureFiles).toBe(
			"From now on, every new PDF, JPEG, PNG, or WebP file in Downloads uploads to Schublade automatically. You will not be asked again for this folder.",
		)
		expect(wording.uploadLabel).toBe("Upload 930 files and start collecting")
		expect(wording.removeLabel).toBe("Remove folder")
		expect(wording.examinationNote).toBeNull()
	})

	it("counts single files in the singular and names files deleted or refused earlier", () => {
		const wording = backlogConfirmationWording("Scans", {
			...surveyedDownloads,
			files_already_archived: 1,
			files_deleted_from_archive: 2,
			files_refused_by_archive: 1,
			files_new: 1,
			new_contents: 1,
			excluded_files_by_reason: {},
			disregarded_files: {},
			unreadable_files: 1,
			files_under_examination: 3,
		})

		expect(wording.existingFiles).toEqual([
			"1 new file uploads now.",
			"1 file is already in Schublade and stays as it is.",
			"2 files were deleted from Schublade earlier and stay deleted.",
			"1 file was refused by Schublade earlier and is not sent again.",
		])
		expect(wording.skippedSummary).toBe("1 file is skipped:")
		expect(wording.skippedGroups).toEqual([{ reason: "Could not be read", count: "1 file" }])
		expect(wording.examinationNote).toBe("Still checking 3 files. The counts update as they finish.")
		expect(wording.uploadLabel).toBe("Upload 1 file and start collecting")
	})

	it("names symbolic links as such and offers to start collecting without an upload when nothing is new", () => {
		const wording = backlogConfirmationWording("Desktop", {
			...surveyedDownloads,
			files_new: 0,
			new_contents: 0,
			excluded_files_by_reason: {},
			disregarded_files: { SymbolicLink: 2 },
		})

		expect(wording.existingFiles[0]).toBe("Nothing new to upload now.")
		expect(wording.skippedSummary).toBe("2 items are skipped:")
		expect(wording.skippedGroups).toEqual([{ reason: "Symbolic links", count: "2 items" }])
		expect(wording.uploadLabel).toBe("Start collecting")
	})
})
