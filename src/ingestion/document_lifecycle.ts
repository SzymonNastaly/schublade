import type { documents } from "../database/schema"

export type DocumentStatus = (typeof documents.$inferSelect)["status"]

// Ingestion moves a document forward through these states. A document without a
// page that needs recognition skips `recognizing_text`. Any unsettled state can fail.
const statusTransitions = {
	processing: ["extracting", "failed"],
	extracting: ["recognizing_text", "classifying", "failed"],
	recognizing_text: ["classifying", "failed"],
	classifying: ["archived", "failed"],
	archived: [],
	failed: [],
} as const satisfies Record<DocumentStatus, ReadonlyArray<DocumentStatus>>

const documentStatuses = Object.keys(statusTransitions) as Array<DocumentStatus>

/** The states a document may hold immediately before it enters `target`. */
export function predecessorStatuses(target: DocumentStatus): Array<DocumentStatus> {
	return documentStatuses.filter((status) =>
		(statusTransitions[status] as ReadonlyArray<DocumentStatus>).includes(target),
	)
}

/** A settled document has no further transition: it is archived or failed. */
export function isSettledStatus(status: DocumentStatus): boolean {
	return statusTransitions[status].length === 0
}
