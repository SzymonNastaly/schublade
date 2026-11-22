import ApplicationBindings
import Foundation

/// The collector's sentences: a folder's state, Needs Attention, what is in flight, the counts, the
/// connection, and the recent uploads. Folder names and times come from the `WordingContext`.
public enum CollectorWording {
	/// The kinds the archive accepts, as a folder's state names them.
	private static let collectingDetail = "New PDF, JPEG, PNG, and WebP files upload automatically."

	public static func folderState(_ folder: FolderStatus) -> FolderStatePresentation {
		switch folder.unavailability {
		case .missing:
			return FolderStatePresentation(
				label: "Missing",
				tone: .failure,
				detail: "The folder is not there. Collecting resumes when it is back."
			)
		case .accessDenied:
			return FolderStatePresentation(
				label: "No access",
				tone: .failure,
				detail: "Allow access in System Settings, Privacy & Security, Files & Folders."
			)
		case nil:
			break
		}
		switch folder.admission {
		case let .surveying(filesUnderExamination):
			let detail = filesUnderExamination > 0
				? "Checking \(DocumentFormatting.countText(filesUnderExamination, singular: "file")). "
				+ "Nothing uploads before you decide."
				: "Looking through the folder. Nothing uploads before you decide."
			return FolderStatePresentation(label: "Surveying", tone: .processing, detail: detail)
		case .awaitingDecision:
			return FolderStatePresentation(label: "Awaiting your decision", tone: .attention, detail: nil)
		case .collecting:
			return FolderStatePresentation(label: "Collecting", tone: .success, detail: collectingDetail)
		}
	}

	public static func attentionSentence(_ item: AttentionItem, context: WordingContext) -> AttentionSentence {
		switch item {
		case .credentialSuspended(.credentialRefused):
			AttentionSentence(
				text: "Schublade refused the token, so nothing uploads. "
					+ "Issue a new API token in Schublade's Settings and paste it here.",
				tone: .failure,
				action: .replaceToken
			)
		case .credentialSuspended(.credentialInsufficient):
			AttentionSentence(
				text: "The token may not upload documents. "
					+ "Issue an API token for the Schublade app in Schublade's Settings and paste it here.",
				tone: .failure,
				action: .replaceToken
			)
		case let .folderUnavailable(folder, .accessDenied):
			AttentionSentence(
				text: "Schublade may not read \(context.folderName(folder.root)). "
					+ "Allow it in System Settings, Privacy & Security, Files & Folders.",
				tone: .failure,
				action: .openFolder(folder.identifier)
			)
		case let .folderUnavailable(folder, .missing):
			AttentionSentence(
				text: "\(context.folderName(folder.root)) is missing. "
					+ "It may have been moved, renamed, or be on a disconnected drive. "
					+ "Collecting resumes when it is back.",
				tone: .failure,
				action: .openFolder(folder.identifier)
			)
		case let .backlogAwaitsDecision(folder):
			AttentionSentence(
				text: "\(context.folderName(folder.root)) waits for your decision.",
				tone: .attention,
				action: .decideBacklog(folder.identifier)
			)
		case let .contentRefused(fileName, reason):
			contentRefusedSentence(fileName: fileName, reason: reason)
		case let .contentFailing(fileName, failures):
			AttentionSentence(
				text: "\(fileName) failed to upload \(DocumentFormatting.countText(UInt64(failures), singular: "time")). "
					+ "The collector keeps trying.",
				tone: .attention,
				action: nil
			)
		}
	}

	private static func contentRefusedSentence(fileName: String, reason: ContentRefusalReason) -> AttentionSentence {
		let because = switch reason {
		case .tooLarge: "it is larger than the archive accepts"
		case .unacceptedKind: "it does not accept this kind of file"
		}
		return AttentionSentence(
			text: "Schublade refused \(fileName), because \(because).",
			tone: .failure,
			action: nil
		)
	}

	public static func activitySentence(_ activity: Activity, context: WordingContext) -> String {
		switch activity {
		case let .listing(folder, directory):
			let name = context.folderName(folder.root)
			return directory.isEmpty ? "Looking through \(name)" : "Looking through \(name)/\(directory)"
		case let .digesting(fileName):
			return "Reading \(fileName)"
		case let .lookingUp(contentCount):
			return "Asking Schublade about \(DocumentFormatting.countText(contentCount, singular: "file"))"
		case let .submitting(fileName, byteSize):
			return "Uploading \(fileName) (\(DocumentFormatting.byteSize(byteSize)))"
		case .followingDocument:
			return "Following a new document through Schublade"
		}
	}

	/// The counts a person cares about. The first is always there; the others only while not zero.
	public static func progressSentences(_ progress: CollectionProgress) -> [String] {
		let documents = DocumentFormatting.countText(progress.documentsInArchive, singular: "document")
		var sentences = ["\(documents) in Schublade"]
		if progress.documentsAwaitingSubmission > 0 {
			let files = DocumentFormatting.countText(progress.documentsAwaitingSubmission, singular: "file")
			sentences.append("\(files) waiting to upload")
		}
		if progress.filesUnderExamination > 0 {
			let files = DocumentFormatting.countText(progress.filesUnderExamination, singular: "file")
			sentences.append("\(files) being checked")
		}
		return sentences
	}

	/// What the collector says while nothing is in flight. Everything is collected only once nothing
	/// waits to upload or is being checked and the archive answers. `connection` is `nil` while the
	/// library has not reported one.
	public static func restingSentence(_ status: CollectorStatus, connection: ArchiveConnection?) -> String {
		guard !status.folders.isEmpty else {
			return "Add a folder to start collecting."
		}
		let watching = "Watching \(DocumentFormatting.countText(UInt64(status.folders.count), singular: "folder")) "
			+ "for new files."
		guard case .configured(_, _, .connected, _, _) = connection else {
			return watching
		}
		let collected = status.progress.documentsAwaitingSubmission == 0
			&& status.progress.filesUnderExamination == 0
		return collected ? "Everything is collected. \(watching)" : watching
	}

	public static func connectionSentence(_ connection: ArchiveConnection, context: WordingContext) -> String {
		guard case let .configured(_, host, condition, _, _) = connection else {
			return "Not connected to an archive yet."
		}
		return switch condition {
		case .connected:
			"Connected to \(host)."
		case .checking:
			"Checking whether the archive answers again."
		case let .unreachable(since, nextAttemptAt):
			"The archive has not answered since \(DocumentFormatting.clockTime(since, context: context)). "
				+ "The next attempt is at \(DocumentFormatting.clockTime(nextAttemptAt, context: context))."
		case let .deferred(until):
			"The archive asked to wait until \(DocumentFormatting.clockTime(until, context: context)). "
				+ "Uploads continue then."
		case .suspended(.credentialRefused):
			"Paused, because Schublade refused the token."
		case .suspended(.credentialInsufficient):
			"Paused, because the token may not upload documents."
		case .archiveOutdated:
			"This archive does not support the desktop application yet. Update your archive first."
		}
	}

	public static func receiptOutcome(_ outcome: DocumentOutcome) -> ReceiptOutcomePresentation {
		switch outcome {
		case .processing:
			ReceiptOutcomePresentation(label: "Processing", tone: .processing)
		case .archived:
			ReceiptOutcomePresentation(label: "Archived", tone: .success)
		case .failed:
			ReceiptOutcomePresentation(label: "Failed", tone: .failure)
		}
	}

	/// "Today, 14:02" or "12 Aug, 9:15", the time of day in the context's locale.
	public static func receiptTime(_ date: Date, context: WordingContext) -> String {
		if context.calendar.isDate(date, inSameDayAs: context.now) {
			return "Today, \(DocumentFormatting.clockTime(date, context: context))"
		}
		let day = context.calendar.component(.day, from: date)
		let month = date.formatted(
			Date.FormatStyle(locale: context.locale, calendar: context.calendar, timeZone: context.calendar.timeZone)
				.month(.abbreviated)
		)
		return "\(day) \(month), \(DocumentFormatting.clockTime(date, context: context))"
	}
}
