import type { documents } from "../database/schema"

export type DocumentStatus = (typeof documents.$inferSelect)["status"]

export type DocumentFailureReason = NonNullable<(typeof documents.$inferSelect)["failureReason"]>

// D1 binds at most 100 parameters per query, and a status request binds one per document.
export const MAXIMUM_DOCUMENTS_PER_STATUS_REQUEST = 100

// Ingestion moves a document forward through these states. A document without a
// page that needs recognition skips `recognizing_text`. Any unsettled state can fail,
// and a member can send a failed document back to `processing` under a new workflow.
// An email without a usable attachment waits in `awaiting_rendering` until phase 7 renders
// its body into a PDF; nothing moves it on before then.
const statusTransitions = {
	awaiting_rendering: [],
	processing: ["extracting", "failed"],
	extracting: ["recognizing_text", "classifying", "failed"],
	recognizing_text: ["classifying", "failed"],
	classifying: ["archived", "failed"],
	archived: [],
	failed: ["processing"],
} as const satisfies Record<DocumentStatus, ReadonlyArray<DocumentStatus>>

const documentStatuses = Object.keys(statusTransitions) as Array<DocumentStatus>

const settledStatuses: ReadonlyArray<DocumentStatus> = ["awaiting_rendering", "archived", "failed"]

/** The states a document may hold immediately before it enters `target`. */
export function predecessorStatuses(target: DocumentStatus): Array<DocumentStatus> {
	return documentStatuses.filter((status) =>
		(statusTransitions[status] as ReadonlyArray<DocumentStatus>).includes(target),
	)
}

/** No workflow is moving a settled document. */
export function isSettledStatus(status: DocumentStatus): boolean {
	return settledStatuses.includes(status)
}
