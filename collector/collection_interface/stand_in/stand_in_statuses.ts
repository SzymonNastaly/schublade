import type { WireCollectorStatus } from "../src/collector_status"

/** Fixed statuses in the core's wire format, one per screen, for screenshots in a plain browser. */
export type StandInScreen = "setup" | "confirmation" | "folders" | "status"

const now = Date.now()
const minutes = (count: number) => now - count * 60_000
const origin = "https://archive.example.org"
const link = (document: string) => `${origin}/documents/${document}`

const counts = {
	paths_stabilizing: 0,
	paths_awaiting_digest: 0,
	paths_digested: 1652,
	paths_excluded: 41,
	paths_unreadable: 0,
	contents_unresolved: 0,
	contents_awaiting_submission: 0,
	contents_present: 1508,
	contents_deleted: 4,
	contents_refused: 1,
	contents_failing: 0,
}

const collecting = (folder: number, root: string) => ({
	folder,
	root,
	admission: { Collecting: { decided_at: minutes(60 * 24 * 3) } },
	availability: "Available" as const,
	files_under_examination: 0,
	backlog: null,
})

const downloadsBacklog = {
	folders: [1],
	candidate_files: 1240,
	files_already_archived: 310,
	files_deleted_from_archive: 0,
	files_refused_by_archive: 0,
	files_new: 930,
	new_contents: 902,
	excluded_files: 35,
	excluded_files_by_reason: { UnrecognizedContent: 31, EmptyFile: 2, ExceedsSizeLimit: 2 },
	disregarded_files: { HiddenEntry: 9, AppleDoubleCompanion: 3, IncompleteDownload: 2 },
	unreadable_files: 0,
	files_under_examination: 0,
}

const connected = { Connected: { archive_origin: origin } }

export const standInStatuses: Record<StandInScreen, WireCollectorStatus> = {
	setup: {
		revision: 1,
		connection: "Unconfigured",
		archive_origin: null,
		folders: [],
		counts: {
			...counts,
			paths_digested: 0,
			paths_excluded: 0,
			contents_present: 0,
			contents_deleted: 0,
			contents_refused: 0,
		},
		activities: [],
		attention: ["ArchiveNotConfigured"],
		recent_receipts: [],
	},
	confirmation: {
		revision: 40,
		connection: connected,
		archive_origin: origin,
		folders: [
			{
				folder: 1,
				root: "/Users/jonas/Downloads",
				admission: "AwaitingDecision",
				availability: "Available",
				files_under_examination: 0,
				backlog: downloadsBacklog,
			},
		],
		counts: { ...counts, contents_awaiting_submission: 902 },
		activities: [],
		attention: [{ BacklogAwaitsDecision: { folders: [1] } }],
		recent_receipts: [],
	},
	folders: {
		revision: 52,
		connection: connected,
		archive_origin: origin,
		folders: [
			collecting(1, "/Users/jonas/Downloads"),
			collecting(2, "/Users/jonas/Desktop"),
			{
				folder: 3,
				root: "/Users/jonas/Documents/Paperwork",
				admission: "Surveying",
				availability: "Available",
				files_under_examination: 214,
				backlog: null,
			},
			{
				folder: 4,
				root: "/Volumes/Archive Disk/Scans",
				admission: { Collecting: { decided_at: minutes(60 * 24 * 20) } },
				availability: "Missing",
				files_under_examination: 0,
				backlog: null,
			},
		],
		counts: { ...counts, paths_awaiting_digest: 180, contents_unresolved: 34 },
		activities: [{ Listing: { folder: 3, directory: "2024/Insurance" } }],
		attention: [{ FolderUnavailable: { folder: 4, availability: "Missing" } }],
		recent_receipts: [],
	},
	status: {
		revision: 77,
		connection: connected,
		archive_origin: origin,
		folders: [collecting(1, "/Users/jonas/Downloads"), collecting(2, "/Users/jonas/Desktop")],
		counts: { ...counts, contents_awaiting_submission: 3, paths_stabilizing: 1 },
		activities: [
			{ Submitting: { file_name: "Tax assessment 2025.pdf", byte_size: 2_418_000 } },
			{ Digesting: { file_name: "IMG_4021.jpeg" } },
		],
		attention: [{ ContentRefused: { file_name: "Lease scan 300 dpi.pdf", reason: "TooLarge" } }],
		recent_receipts: [
			{
				document: "0b1c7e52-3f7a-4c61-9a10-8d2b55e1c901",
				document_link: link("0b1c7e52-3f7a-4c61-9a10-8d2b55e1c901"),
				file_name: "Electricity bill November.pdf",
				received_at: minutes(2),
				status: "Classifying",
			},
			{
				document: "5e8f0a13-77c2-4b9e-8e41-2a6f3c0d7b18",
				document_link: link("5e8f0a13-77c2-4b9e-8e41-2a6f3c0d7b18"),
				file_name: "Pharmacy receipt.jpeg",
				received_at: minutes(18),
				status: "Archived",
			},
			{
				document: "9a2d4c66-1b0e-4f3a-b5d7-60c8e2f41a77",
				document_link: link("9a2d4c66-1b0e-4f3a-b5d7-60c8e2f41a77"),
				file_name: "Insurance policy 2026.pdf",
				received_at: minutes(47),
				status: "Archived",
			},
			{
				document: "c41f6b08-2e9d-4a5c-8f13-7d0b9e6a2c35",
				document_link: link("c41f6b08-2e9d-4a5c-8f13-7d0b9e6a2c35"),
				file_name: "Scan 2026-11-14.pdf",
				received_at: minutes(95),
				status: { Failed: { failure_reason: "unreadable_page" } },
			},
		],
	},
}
