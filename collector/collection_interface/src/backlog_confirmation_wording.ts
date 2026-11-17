import { countOf } from "./number_wording"
import type { BacklogSummary, DisregardReason, ExclusionReason } from "./collector_status"

/** The four kinds the archive accepts, as the confirmation names them. */
const acceptedKinds = "PDF, JPEG, PNG, or WebP file"

/**
 * Why something already in the folder is not uploaded, in the words of the confirmation, and what
 * it counts: an excluded or unreadable entry is a file, while a disregarded entry can be a folder,
 * a package, or a link, so it counts as an item.
 */
const skipReasons: Record<ExclusionReason | DisregardReason | "Unreadable", { words: string; noun: SkippedNoun }> = {
	UnrecognizedContent: { words: `Not a ${acceptedKinds}`, noun: "file" },
	EmptyFile: { words: "Empty", noun: "file" },
	ExceedsSizeLimit: { words: "Larger than 25 MB", noun: "file" },
	CloudPlaceholder: { words: "In iCloud Drive, not downloaded to this Mac", noun: "file" },
	Unreadable: { words: "Could not be read", noun: "file" },
	IncompleteDownload: { words: "Unfinished downloads", noun: "item" },
	HiddenEntry: { words: "Hidden files and folders", noun: "item" },
	AppleDoubleCompanion: { words: "Hidden files and folders", noun: "item" },
	PackageDirectory: { words: "App or document packages", noun: "item" },
	SymbolicLink: { words: "Symbolic links", noun: "item" },
	SpecialFile: { words: "Not regular files", noun: "item" },
}

type SkippedNoun = "file" | "item"

export interface SkippedGroup {
	reason: string
	count: string
}

export interface BacklogConfirmationWording {
	heading: string
	/** What happens to the files the survey found, one sentence each. */
	existingFiles: Array<string>
	/** "57 items are skipped:", or null when none are. */
	skippedSummary: string | null
	/** The skipped files grouped by reason, largest group first. */
	skippedGroups: Array<SkippedGroup>
	/** What happens to every file that arrives after the decision. */
	futureFiles: string
	examinationNote: string | null
	uploadLabel: string
	removeLabel: string
}

export function backlogConfirmationWording(folderName: string, backlog: BacklogSummary): BacklogConfirmationWording {
	const existingFiles: Array<string> = []
	const { files_new, new_contents, files_already_archived, files_deleted_from_archive, files_refused_by_archive } =
		backlog
	if (files_new === 0) {
		existingFiles.push("Nothing new to upload now.")
	} else {
		const copies =
			new_contents < files_new
				? ` Identical copies upload once, so Schublade receives ${countOf(new_contents, "distinct file")}.`
				: ""
		existingFiles.push(`${countOf(files_new, "new file")} ${agree(files_new, "uploads", "upload")} now.${copies}`)
	}
	if (files_already_archived > 0) {
		existingFiles.push(
			`${countOf(files_already_archived, "file")} ${agree(files_already_archived, "is", "are")} already in Schublade and ${agree(files_already_archived, "stays as it is", "stay as they are")}.`,
		)
	}
	if (files_deleted_from_archive > 0) {
		existingFiles.push(
			`${countOf(files_deleted_from_archive, "file")} ${agree(files_deleted_from_archive, "was", "were")} deleted from Schublade earlier and ${agree(files_deleted_from_archive, "stays", "stay")} deleted.`,
		)
	}
	if (files_refused_by_archive > 0) {
		existingFiles.push(
			`${countOf(files_refused_by_archive, "file")} ${agree(files_refused_by_archive, "was", "were")} refused by Schublade earlier and ${agree(files_refused_by_archive, "is", "are")} not sent again.`,
		)
	}

	const skipped = new Map<string, { count: number; noun: SkippedNoun }>()
	const skip = (reason: keyof typeof skipReasons, count: number | undefined) => {
		if (count === undefined || count === 0) return
		const { words, noun } = skipReasons[reason]
		skipped.set(words, { count: (skipped.get(words)?.count ?? 0) + count, noun })
	}
	for (const [reason, count] of Object.entries(backlog.excluded_files_by_reason)) {
		skip(reason as ExclusionReason, count)
	}
	for (const [reason, count] of Object.entries(backlog.disregarded_files)) {
		skip(reason as DisregardReason, count)
	}
	skip("Unreadable", backlog.unreadable_files)
	const skippedGroups = [...skipped.entries()]
		.sort(
			([firstReason, first], [secondReason, second]) =>
				second.count - first.count || firstReason.localeCompare(secondReason),
		)
		.map(([reason, { count, noun }]) => ({ reason, count: countOf(count, noun) }))
	const skippedTotal = [...skipped.values()].reduce((total, { count }) => total + count, 0)
	const skippedNoun = [...skipped.values()].every(({ noun }) => noun === "file") ? "file" : "item"

	return {
		heading: `Collect from ${folderName}?`,
		existingFiles,
		skippedSummary:
			skippedTotal === 0 ? null : `${countOf(skippedTotal, skippedNoun)} ${agree(skippedTotal, "is", "are")} skipped:`,
		skippedGroups,
		futureFiles: `From now on, every new ${acceptedKinds} in ${folderName} uploads to Schublade automatically. You will not be asked again for this folder.`,
		examinationNote:
			backlog.files_under_examination > 0
				? `Still checking ${countOf(backlog.files_under_examination, "file")}. The counts update as they finish.`
				: null,
		uploadLabel:
			backlog.files_new === 0
				? "Start collecting"
				: `Upload ${countOf(backlog.files_new, "file")} and start collecting`,
		removeLabel: "Remove folder",
	}
}

/** The verb or phrase that agrees with a count of files. */
function agree(count: number, singular: string, plural: string): string {
	return count === 1 ? singular : plural
}
