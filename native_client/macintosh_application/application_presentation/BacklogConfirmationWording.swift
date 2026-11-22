import ApplicationBindings

/// The confirmation a folder awaits after its survey: what happens to the files already there, and
/// that every later file uploads without asking.
public struct BacklogConfirmationWording: Equatable, Sendable {
	/// The four kinds the archive accepts, as the confirmation names them.
	private static let acceptedKinds = "PDF, JPEG, PNG, or WebP file"

	public let heading: String
	public let existingFilesHeading: String
	/// What happens to the files the survey found, one sentence each.
	public let existingFiles: [String]
	/// "57 items are skipped:", or `nil` when none are.
	public let skippedSummary: String?
	/// The skipped files grouped by reason, largest group first.
	public let skippedGroups: [SkippedGroup]
	public let examinationNote: String?
	public let futureFilesHeading: String
	/// What happens to every file that arrives after the decision.
	public let futureFiles: String
	public let uploadLabel: String
	public let removeLabel: String

	public static func make(folderName: String, backlog: BacklogSummary) -> BacklogConfirmationWording {
		let skipped = skippedTotals(backlog.skipped)
		let skippedTotal = skipped.reduce(UInt64(0)) { $0 + $1.total.count }
		let skippedNoun = skipped.allSatisfy { $0.total.noun == "file" } ? "file" : "item"
		return BacklogConfirmationWording(
			heading: "Collect from \(folderName)?",
			existingFilesHeading: "The files already there",
			existingFiles: existingFileSentences(backlog),
			skippedSummary: skippedTotal == 0
				? nil
				: "\(countOf(skippedTotal, skippedNoun)) \(agree(skippedTotal, "is", "are")) skipped:",
			skippedGroups: skipped.map { entry in
				SkippedGroup(reason: entry.words, count: countOf(entry.total.count, entry.total.noun))
			},
			examinationNote: backlog.filesUnderExamination > 0
				? "Still checking \(countOf(backlog.filesUnderExamination, "file")). The counts update as they finish."
				: nil,
			futureFilesHeading: "From now on",
			futureFiles: "From now on, every new \(acceptedKinds) in \(folderName) uploads to Schublade automatically. "
				+ "You will not be asked again for this folder.",
			uploadLabel: backlog.filesNew == 0
				? "Start collecting"
				: "Upload \(countOf(backlog.filesNew, "file")) and start collecting",
			removeLabel: "Remove folder"
		)
	}

	private static func existingFileSentences(_ backlog: BacklogSummary) -> [String] {
		var sentences: [String] = []
		let filesNew = backlog.filesNew
		if filesNew == 0 {
			sentences.append("Nothing new to upload now.")
		} else {
			let copies = backlog.newContents < filesNew
				? " Identical copies upload once, so Schublade receives \(countOf(backlog.newContents, "distinct file"))."
				: ""
			sentences.append("\(countOf(filesNew, "new file")) \(agree(filesNew, "uploads", "upload")) now.\(copies)")
		}
		let archived = backlog.filesAlreadyArchived
		if archived > 0 {
			sentences.append(
				"\(countOf(archived, "file")) \(agree(archived, "is", "are")) already in Schublade "
					+ "and \(agree(archived, "stays as it is", "stay as they are"))."
			)
		}
		let deleted = backlog.filesDeletedFromArchive
		if deleted > 0 {
			sentences.append(
				"\(countOf(deleted, "file")) \(agree(deleted, "was", "were")) deleted from Schublade earlier "
					+ "and \(agree(deleted, "stays", "stay")) deleted."
			)
		}
		let refused = backlog.filesRefusedByArchive
		if refused > 0 {
			sentences.append(
				"\(countOf(refused, "file")) \(agree(refused, "was", "were")) refused by Schublade earlier "
					+ "and \(agree(refused, "is", "are")) not sent again."
			)
		}
		return sentences
	}

	/// The skipped counts merged by their words, largest first, then alphabetically.
	private static func skippedTotals(_ counts: [SkippedCount]) -> [(words: String, total: SkippedTotal)] {
		var totals: [String: SkippedTotal] = [:]
		// The core leaves out zero counts, so every reason here names at least one entry.
		for skippedCount in counts {
			let (words, noun) = skipReasonWording(skippedCount.reason)
			totals[words, default: SkippedTotal(noun: noun, count: 0)].count += skippedCount.count
		}
		return totals.map { (words: $0.key, total: $0.value) }.sorted { first, second in
			first.total.count != second.total.count
				? first.total.count > second.total.count
				: first.words < second.words
		}
	}

	/// Why something already in the folder is not uploaded, and what it counts: an excluded or
	/// unreadable entry is a file, while a disregarded entry can be a folder, a package, or a link,
	/// so it counts as an item.
	private static func skipReasonWording(_ reason: SkipReason) -> (words: String, noun: String) {
		switch reason {
		case .unrecognizedContent: ("Not a \(acceptedKinds)", "file")
		case .emptyFile: ("Empty", "file")
		case .exceedsSizeLimit: ("Larger than 25 MB", "file")
		case .cloudPlaceholder: ("In iCloud Drive, not downloaded to this Mac", "file")
		case .unreadable: ("Could not be read", "file")
		case .incompleteDownload: ("Unfinished downloads", "item")
		case .hiddenEntry, .appleDoubleCompanion: ("Hidden files and folders", "item")
		case .packageDirectory: ("App or document packages", "item")
		case .symbolicLink: ("Symbolic links", "item")
		case .specialFile: ("Not regular files", "item")
		}
	}

	private static func countOf(_ count: UInt64, _ noun: String) -> String {
		DocumentFormatting.countText(count, singular: noun)
	}

	/// The verb or phrase that agrees with a count of files.
	private static func agree(_ count: UInt64, _ singular: String, _ plural: String) -> String {
		count == 1 ? singular : plural
	}
}
