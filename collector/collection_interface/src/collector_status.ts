/**
 * The collector's status and refusals as the window uses them. The core serializes its Rust enums
 * with serde's external tagging (`"Surveying"`, `{ "Collecting": { "decided_at": 1 } }`); each union
 * here carries a `kind` instead, and `ExternallyTagged` derives the wire shape from it, so the two
 * cannot drift apart. Field names stay as the core writes them.
 */

type ExternallyTagged<TVariant extends { kind: string }> = TVariant extends { kind: infer Kind extends string }
	? keyof Omit<TVariant, "kind"> extends never
		? Kind
		: { [Name in Kind]: Omit<TVariant, "kind"> }
	: never

export function fromExternalTag<TVariant extends { kind: string }>(value: ExternallyTagged<TVariant>): TVariant {
	if (typeof value === "string") return { kind: value } as unknown as TVariant
	const [kind, fields] = Object.entries<object>(value)[0] ?? []
	return { kind, ...fields } as unknown as TVariant
}

export type SuspensionReason = "CredentialRefused" | "CredentialInsufficient"
export type FolderAvailability = "Available" | "Missing" | "AccessDenied"
export type ExclusionReason = "EmptyFile" | "ExceedsSizeLimit" | "CloudPlaceholder" | "UnrecognizedContent"
export type DisregardReason =
	"HiddenEntry" | "AppleDoubleCompanion" | "IncompleteDownload" | "PackageDirectory" | "SymbolicLink" | "SpecialFile"
export type RefusalReason = "TooLarge" | "UnacceptedKind"

export type ConnectionStatus =
	| { kind: "Unconfigured" }
	| { kind: "Connected"; archive_origin: string }
	| { kind: "Unreachable"; since: number; next_attempt_at: number }
	| { kind: "Checking" }
	| { kind: "Deferred"; until: number }
	| { kind: "Suspended"; reason: SuspensionReason; since: number }

export type FolderAdmission =
	{ kind: "Surveying" } | { kind: "AwaitingDecision" } | { kind: "Collecting"; decided_at: number }

export interface BacklogSummary {
	folders: Array<number>
	candidate_files: number
	files_already_archived: number
	files_deleted_from_archive: number
	files_refused_by_archive: number
	files_new: number
	new_contents: number
	excluded_files: number
	excluded_files_by_reason: Partial<Record<ExclusionReason, number>>
	disregarded_files: Partial<Record<DisregardReason, number>>
	unreadable_files: number
	files_under_examination: number
}

export interface FolderStatus {
	folder: number
	root: string
	/** The last component of the root, as Finder names the folder. */
	name: string
	admission: FolderAdmission
	availability: FolderAvailability
	files_under_examination: number
	backlog: BacklogSummary | null
}

export interface StateCounts {
	paths_stabilizing: number
	paths_awaiting_digest: number
	paths_digested: number
	paths_excluded: number
	paths_unreadable: number
	contents_unresolved: number
	contents_awaiting_submission: number
	contents_present: number
	contents_deleted: number
	contents_refused: number
	contents_failing: number
}

export type Activity =
	| { kind: "Listing"; folder: number; directory: string }
	| { kind: "Digesting"; file_name: string }
	| { kind: "LookingUp"; content_count: number }
	| { kind: "Submitting"; file_name: string; byte_size: number }
	| { kind: "FollowingDocument" }

export type AttentionItem =
	| { kind: "ArchiveNotConfigured" }
	| { kind: "CredentialSuspended"; reason: SuspensionReason }
	| { kind: "FolderUnavailable"; folder: number; availability: FolderAvailability }
	| { kind: "BacklogAwaitsDecision"; folders: Array<number> }
	| { kind: "ContentRefused"; file_name: string; reason: RefusalReason }
	| { kind: "ContentFailing"; file_name: string; failures: number }

export type DocumentStatus =
	| { kind: "AwaitingRendering" }
	| { kind: "Processing" }
	| { kind: "Extracting" }
	| { kind: "RecognizingText" }
	| { kind: "Classifying" }
	| { kind: "Archived" }
	| { kind: "Failed"; failure_reason: string | null }

export interface Receipt {
	document: string
	document_link: string
	file_name: string
	received_at: number
	status: DocumentStatus | null
}

export interface CollectorStatus {
	revision: number
	connection: ConnectionStatus
	archive_origin: string | null
	folders: Array<FolderStatus>
	counts: StateCounts
	activities: Array<Activity>
	attention: Array<AttentionItem>
	recent_receipts: Array<Receipt>
}

/** `CommandRefusal` of the core: why the collector did not carry out a command. */
export type CommandRefusal =
	| { kind: "ArchiveAddressInvalid"; detail: string }
	| { kind: "CredentialStorageFailed"; detail: string }
	| { kind: "FolderRootNotADirectory"; root: string }
	| { kind: "FolderAlreadyEnrolled"; folder: number }
	| { kind: "FolderOverlapsEnrolledFolder"; folder: number }
	| { kind: "FolderUnknown"; folder: number }
	| { kind: "SurveyIncomplete"; folder: number }
	| { kind: "BacklogAlreadyDecided"; folder: number }
	| { kind: "IdleTimeout" }
	| { kind: "CollectorStopped" }
	| { kind: "StoreFailed"; detail: string }

/**
 * The application's refusals: a connection attempt that failed before anything was stored, a
 * preference it could not apply, or a refusal of the core.
 */
type ApplicationRefusal =
	| { kind: "AddressInvalid"; detail: string }
	| { kind: "TokenRefused" }
	| { kind: "TokenInsufficient" }
	| { kind: "ArchiveUnreachable" }
	| { kind: "ArchiveUnavailable"; retry_after_seconds: number }
	| { kind: "ArchiveFailed" }
	| { kind: "NotAnArchive"; detail: string }
	| { kind: "PreferenceNotApplied"; detail: string }
	| { kind: "CommandRefused"; refusal: ExternallyTagged<CommandRefusal> }

export type Refusal = CommandRefusal | Exclude<ApplicationRefusal, { kind: "CommandRefused" }>

type WireBacklogSummary = BacklogSummary

interface WireFolderStatus {
	folder: number
	root: string
	admission: ExternallyTagged<FolderAdmission>
	availability: FolderAvailability
	files_under_examination: number
	backlog: WireBacklogSummary | null
}

interface WireReceipt extends Omit<Receipt, "status"> {
	status: ExternallyTagged<DocumentStatus> | null
}

export interface WireCollectorStatus {
	revision: number
	connection: ExternallyTagged<ConnectionStatus>
	archive_origin: string | null
	folders: Array<WireFolderStatus>
	counts: StateCounts
	activities: Array<ExternallyTagged<Activity>>
	attention: Array<ExternallyTagged<AttentionItem>>
	recent_receipts: Array<WireReceipt>
}

export type WireApplicationRefusal = ExternallyTagged<ApplicationRefusal>

export type CollectorEvent =
	{ kind: "StatusChanged"; revision: number } | { kind: "DocumentReceived"; document_link: string; file_name: string }
export type WireCollectorEvent = ExternallyTagged<CollectorEvent>

export function folderName(root: string): string {
	const components = root.split("/").filter((component) => component !== "")
	return components.at(-1) ?? root
}

export function parseCollectorStatus(wire: WireCollectorStatus): CollectorStatus {
	return {
		revision: wire.revision,
		connection: fromExternalTag<ConnectionStatus>(wire.connection),
		archive_origin: wire.archive_origin,
		folders: wire.folders.map((folder) => ({
			...folder,
			name: folderName(folder.root),
			admission: fromExternalTag<FolderAdmission>(folder.admission),
		})),
		counts: wire.counts,
		activities: wire.activities.map((activity) => fromExternalTag<Activity>(activity)),
		attention: wire.attention.map((item) => fromExternalTag<AttentionItem>(item)),
		recent_receipts: wire.recent_receipts.map((receipt) => ({
			...receipt,
			status: receipt.status === null ? null : fromExternalTag<DocumentStatus>(receipt.status),
		})),
	}
}

export function parseRefusal(wire: WireApplicationRefusal): Refusal {
	const refusal = fromExternalTag<ApplicationRefusal>(wire)
	return refusal.kind === "CommandRefused" ? fromExternalTag<CommandRefusal>(refusal.refusal) : refusal
}

/** Thrown by the bridge when the collector refused a command, carrying the refusal itself. */
export class RefusalError extends Error {
	readonly refusal: Refusal

	constructor(refusal: Refusal) {
		super(refusal.kind)
		this.refusal = refusal
	}
}
