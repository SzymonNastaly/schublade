import { byteSize, countOf } from "./number_wording"
import type {
	Activity,
	AttentionItem,
	CollectorStartFailure,
	CollectorStatus,
	ConnectionStatus,
	DocumentStatus,
	FolderStatus,
	Refusal,
	StateCounts,
} from "./collector_status"

export type Tone = "processing" | "attention" | "failure" | "success" | "neutral"

/** What a status asks the person to do, so the window can offer the matching control. */
export type AttentionAction = "replace_token" | "decide_backlog" | "open_folders" | null

export interface AttentionSentence {
	sentence: string
	action: AttentionAction
}

export type ClockTime = (timestamp: number) => string

const folderNames = (status: Pick<CollectorStatus, "folders">) =>
	new Map(status.folders.map((folder) => [folder.folder, folder.name]))

function nameOf(names: Map<number, string>, folder: number): string {
	return names.get(folder) ?? "A folder"
}

/** How to collect into another archive: the collector's records belong to the one it connected first. */
export const startingOverInstructions =
	"To collect into another archive, start over: quit Schublade Collector, then in Finder choose Go > Go to Folder, enter ~/Library/Application Support, move the folder org.schublade.collector to the Trash, and open Schublade Collector again."

export function connectionSentence(connection: ConnectionStatus, clockTime: ClockTime): string {
	switch (connection.kind) {
		case "Unconfigured":
			return "Not connected to an archive yet."
		case "Connected":
			return `Connected to ${new URL(connection.archive_origin).host}.`
		case "Checking":
			return "Checking whether the archive answers again."
		case "Unreachable":
			return `The archive has not answered since ${clockTime(connection.since)}. The next attempt is at ${clockTime(connection.next_attempt_at)}.`
		case "Deferred":
			return `The archive asked to wait until ${clockTime(connection.until)}. Uploads continue then.`
		case "Suspended":
			return connection.reason === "CredentialRefused"
				? "Paused, because Schublade refused the token."
				: "Paused, because the token may not upload documents."
	}
}

export function attentionSentence(item: AttentionItem, status: Pick<CollectorStatus, "folders">): AttentionSentence {
	const names = folderNames(status)
	switch (item.kind) {
		case "ArchiveNotConfigured":
			return { sentence: "Connect an archive to start collecting.", action: "replace_token" }
		case "CredentialSuspended":
			return item.reason === "CredentialRefused"
				? {
						sentence:
							"Schublade refused the token, so nothing uploads. Issue a new API token in Schublade's Settings and paste it here.",
						action: "replace_token",
					}
				: {
						sentence:
							"The token may not upload documents. Issue an API token with the permission Ingest documents in Schublade's Settings and paste it here.",
						action: "replace_token",
					}
		case "FolderUnavailable":
			return item.availability === "AccessDenied"
				? {
						sentence: `Schublade Collector may not read ${nameOf(names, item.folder)}. Allow it in System Settings, Privacy & Security, Files & Folders.`,
						action: "open_folders",
					}
				: {
						sentence: `${nameOf(names, item.folder)} is missing. It may have been moved, renamed, or be on a disconnected drive. Collecting resumes when it is back.`,
						action: "open_folders",
					}
		case "BacklogAwaitsDecision": {
			const listed = item.folders.map((folder) => nameOf(names, folder)).join(" and ")
			return {
				sentence: `${listed} ${item.folders.length === 1 ? "waits" : "wait"} for your decision.`,
				action: "decide_backlog",
			}
		}
		case "ContentRefused":
			return {
				sentence:
					item.reason === "TooLarge"
						? `Schublade refused ${item.file_name}, because it is larger than the archive accepts.`
						: `Schublade refused ${item.file_name}, because it does not accept this kind of file.`,
				action: null,
			}
		case "ContentFailing":
			return {
				sentence: `${item.file_name} failed to upload ${countOf(item.failures, "time")}. The collector keeps trying.`,
				action: null,
			}
	}
}

export function activitySentence(activity: Activity, status: Pick<CollectorStatus, "folders">): string {
	switch (activity.kind) {
		case "Listing": {
			const name = nameOf(folderNames(status), activity.folder)
			return activity.directory === "" ? `Looking through ${name}` : `Looking through ${name}/${activity.directory}`
		}
		case "Digesting":
			return `Reading ${activity.file_name}`
		case "LookingUp":
			return `Asking Schublade about ${countOf(activity.content_count, "file")}`
		case "Submitting":
			return `Uploading ${activity.file_name} (${byteSize(activity.byte_size)})`
		case "FollowingDocument":
			return "Following a new document through Schublade"
	}
}

/** Files still settling, being read, or waiting for the archive's answer about their content. */
function filesUnderExamination(counts: StateCounts): number {
	return counts.paths_stabilizing + counts.paths_awaiting_digest + counts.contents_unresolved
}

/** The counts a person cares about, from the core's state counts. */
export function progressSentences(counts: StateCounts): Array<string> {
	const examining = filesUnderExamination(counts)
	return [
		`${countOf(counts.contents_present, "document")} in Schublade`,
		...(counts.contents_awaiting_submission > 0
			? [`${countOf(counts.contents_awaiting_submission, "file")} waiting to upload`]
			: []),
		...(examining > 0 ? [`${countOf(examining, "file")} being checked`] : []),
	]
}

/**
 * What the collector says while nothing is in flight. Everything is collected only once nothing
 * waits to upload or is being checked and the archive answers; every enrolled folder is watched.
 */
export function restingSentence(status: Pick<CollectorStatus, "connection" | "folders" | "counts">): string {
	if (status.folders.length === 0) return "Add a folder to start collecting."
	const watching = `Watching ${countOf(status.folders.length, "folder")} for new files.`
	const collected =
		status.connection.kind === "Connected" &&
		status.counts.contents_awaiting_submission === 0 &&
		filesUnderExamination(status.counts) === 0
	return collected ? `Everything is collected. ${watching}` : watching
}

export interface FolderState {
	label: string
	tone: Tone
	detail: string | null
}

export function folderState(folder: FolderStatus): FolderState {
	if (folder.availability === "Missing") {
		return { label: "Missing", tone: "failure", detail: "The folder is not there. Collecting resumes when it is back." }
	}
	if (folder.availability === "AccessDenied") {
		return {
			label: "No access",
			tone: "failure",
			detail: "Allow access in System Settings, Privacy & Security, Files & Folders.",
		}
	}
	switch (folder.admission.kind) {
		case "Surveying":
			return {
				label: "Surveying",
				tone: "processing",
				detail:
					folder.files_under_examination > 0
						? `Checking ${countOf(folder.files_under_examination, "file")}. Nothing uploads before you decide.`
						: "Looking through the folder. Nothing uploads before you decide.",
			}
		case "AwaitingDecision":
			return { label: "Awaiting your decision", tone: "attention", detail: null }
		case "Collecting":
			return {
				label: "Collecting",
				tone: "success",
				detail: "New PDF, JPEG, PNG, and WebP files upload automatically.",
			}
	}
}

export function documentStatusLabel(status: DocumentStatus | null): { label: string; tone: Tone } {
	switch (status?.kind) {
		case "Archived":
			return { label: "Archived", tone: "success" }
		case "Failed":
			return { label: "Failed", tone: "failure" }
		default:
			return { label: "Processing", tone: "processing" }
	}
}

export interface StartFailureWording {
	/** What went wrong, in plain words. */
	explanation: string
	/** What the person can do about it. */
	remedy: string
	/** The system's own words, for whoever helps; null when the explanation says it all. */
	detail: string | null
}

const reopenRemedy = "Quit Schublade Collector and open it again. If this keeps happening, restart your Mac."

export function startFailureWording(failure: CollectorStartFailure): StartFailureWording {
	switch (failure.kind) {
		case "DatabaseInUse":
			return {
				explanation: "Another copy of Schublade Collector is already collecting on this Mac with the same data.",
				remedy:
					"Quit the other copy from its drawer in the menu bar or from Activity Monitor. Then quit this one and open Schublade Collector again.",
				detail: null,
			}
		case "DatabaseNewerThanApplication":
			return {
				explanation:
					"A newer version of Schublade Collector ran on this Mac before, and this older version cannot read what it saved.",
				remedy: "Install the newest version of Schublade Collector and open it.",
				detail: null,
			}
		case "DataDirectoryUnavailable":
			return {
				explanation: "Schublade Collector could not create its folder in Application Support.",
				remedy: `Check that your disk has free space. ${reopenRemedy}`,
				detail: failure.detail,
			}
		case "DatabaseUnusable":
			return {
				explanation: "Schublade Collector could not open the file where it keeps track of your folders.",
				remedy: reopenRemedy,
				detail: failure.detail,
			}
		case "WatcherUnavailable":
			return {
				explanation: "Schublade Collector could not start watching your folders for new files.",
				remedy: reopenRemedy,
				detail: failure.detail,
			}
	}
}

export function refusalSentence(refusal: Refusal, status: Pick<CollectorStatus, "folders"> | undefined): string {
	const names = folderNames(status ?? { folders: [] })
	switch (refusal.kind) {
		case "AddressInvalid":
		case "ArchiveAddressInvalid":
			return "This is not an archive address. Copy the address from your browser, such as https://archive.example.org."
		case "ArchiveOriginDiffers":
			return `This collector already collects into ${new URL(refusal.connected_origin).host}. ${startingOverInstructions}`
		case "TokenRefused":
			return "Schublade refused this token. Check that you copied all of it and that it was not revoked."
		case "TokenInsufficient":
			return "This token may not upload documents. Issue one with the permission Ingest documents."
		case "ArchiveUnreachable":
			return "The archive could not be reached. Check the address and your internet connection."
		case "ArchiveUnavailable":
			return "The archive is busy right now. Try again in a few minutes."
		case "ArchiveFailed":
			return "The archive had a problem answering. Try again in a few minutes."
		case "NotAnArchive":
			return "This address answers, but not like a Schublade archive. Check that it is the address of your archive."
		case "CollectorNotStarted":
			return startFailureWording(refusal.failure).explanation
		case "PreferenceNotApplied":
			return `The setting could not be changed: ${refusal.detail}`
		case "CredentialStorageFailed":
			return "The token could not be saved in the Keychain. Allow Schublade Collector to use the Keychain and try again."
		case "FolderRootNotADirectory":
			return `${refusal.root} is not a folder.`
		case "FolderAlreadyEnrolled":
			return `${nameOf(names, refusal.folder)} is collected already.`
		case "FolderOverlapsEnrolledFolder":
			return `This folder is inside ${nameOf(names, refusal.folder)} or contains it. Each file can be collected from one folder only.`
		case "FolderUnknown":
			return "This folder is no longer collected."
		case "SurveyIncomplete":
			return `${nameOf(names, refusal.folder)} is still being surveyed.`
		case "BacklogAlreadyDecided":
			return `${nameOf(names, refusal.folder)} is collecting already.`
		case "IdleTimeout":
		case "CollectorStopped":
			return "The collector stopped. Quit Schublade Collector and open it again."
		case "StoreFailed":
			return `The collector could not save its state: ${refusal.detail}`
		default:
			return "Something went wrong."
	}
}
