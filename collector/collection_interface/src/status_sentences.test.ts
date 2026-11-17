import { describe, expect, it } from "vitest"
import { parseCollectorStatus, parseRefusal } from "./collector_status"
import { attentionSentence, connectionSentence, folderState, refusalSentence } from "./status_sentences"
import type { WireCollectorStatus } from "./collector_status"

const emptyCounts = {
	paths_stabilizing: 0,
	paths_awaiting_digest: 0,
	paths_digested: 0,
	paths_excluded: 0,
	paths_unreadable: 0,
	contents_unresolved: 0,
	contents_awaiting_submission: 0,
	contents_present: 0,
	contents_deleted: 0,
	contents_refused: 0,
	contents_failing: 0,
}

const wireStatus: WireCollectorStatus = {
	revision: 7,
	connection: { Suspended: { reason: "CredentialRefused", since: 1_763_400_000_000 } },
	archive_origin: "https://archive.example.org",
	folders: [
		{
			folder: 1,
			root: "/Users/jonas/Downloads",
			admission: { Collecting: { decided_at: 1_763_300_000_000 } },
			availability: "Available",
			files_under_examination: 0,
			backlog: null,
		},
		{
			folder: 2,
			root: "/Volumes/Archive Disk/Scans/",
			admission: "Surveying",
			availability: "Missing",
			files_under_examination: 4,
			backlog: null,
		},
	],
	counts: emptyCounts,
	activities: [],
	attention: [
		{ CredentialSuspended: { reason: "CredentialRefused" } },
		{ FolderUnavailable: { folder: 2, availability: "Missing" } },
		{ ContentRefused: { file_name: "Holiday video.pdf", reason: "TooLarge" } },
		{ ContentFailing: { file_name: "Invoice.pdf", failures: 4 } },
	],
	recent_receipts: [],
}

describe("the status sentences", () => {
	const status = parseCollectorStatus(wireStatus)

	it("names each attention item in plain words, with the folder's name rather than its identifier", () => {
		expect(status.attention.map((item) => attentionSentence(item, status))).toEqual([
			{
				sentence:
					"Schublade refused the token, so nothing uploads. Issue a new API token in Schublade's Settings and paste it here.",
				action: "replace_token",
			},
			{
				sentence:
					"Scans is missing. It may have been moved, renamed, or be on a disconnected drive. Collecting resumes when it is back.",
				action: "open_folders",
			},
			{
				sentence: "Schublade refused Holiday video.pdf, because it is larger than the archive accepts.",
				action: null,
			},
			{ sentence: "Invoice.pdf failed to upload 4 times. The collector keeps trying.", action: null },
		])
	})

	it("reads a folder's state from its availability before its admission", () => {
		expect(status.folders.map((folder) => [folder.name, folderState(folder).label])).toEqual([
			["Downloads", "Collecting"],
			["Scans", "Missing"],
		])
	})

	it("says why the connection is paused", () => {
		expect(connectionSentence(status.connection, () => "14:02")).toBe("Paused, because Schublade refused the token.")
		expect(
			connectionSentence({ kind: "Unreachable", since: 1, next_attempt_at: 2 }, (time) =>
				time === 1 ? "14:02" : "14:07",
			),
		).toBe("The archive has not answered since 14:02. The next attempt is at 14:07.")
	})

	it("words a refusal of the core and of the connection attempt", () => {
		const overlap = parseRefusal({ CommandRefused: { refusal: { FolderOverlapsEnrolledFolder: { folder: 1 } } } })
		expect(refusalSentence(overlap, status)).toBe(
			"This folder is inside Downloads or contains it. Each file can be collected from one folder only.",
		)
		expect(refusalSentence(parseRefusal("TokenRefused"), status)).toBe(
			"Schublade refused this token. Check that you copied all of it and that it was not revoked.",
		)
	})
})
