import { isSettledStatus } from "../ingestion/document_lifecycle"
import type { DocumentStatusRecord } from "../archive/document_listing"
import type { DocumentFailureReason, DocumentStatus } from "../ingestion/document_lifecycle"
import type { UploadOutcome } from "../ingestion/document_upload"

export type TrackedUpload =
	| { key: string; fileName: string; stage: "uploading" }
	| { key: string; fileName: string; stage: "refused"; reason: string }
	| {
			key: string
			fileName: string
			stage: "tracked"
			documentId: string
			title: string | null
			status: DocumentStatus
			failureReason: DocumentFailureReason | null
	  }

export type TrackedUploadEvent =
	| { kind: "submitted"; uploads: ReadonlyArray<{ key: string; fileName: string }> }
	/** The outcomes of one request, in the order of its keys. */
	| { kind: "answered"; keys: ReadonlyArray<string>; outcomes: ReadonlyArray<UploadOutcome> }
	| { kind: "statuses_received"; records: ReadonlyArray<DocumentStatusRecord> }
	| { kind: "retried"; documentId: string }
	| { kind: "document_deleted"; documentId: string }
	| { kind: "dismissed"; key: string }
	| { kind: "finished_cleared" }

export function isFinishedUpload(upload: TrackedUpload): boolean {
	return upload.stage === "refused" || (upload.stage === "tracked" && isSettledStatus(upload.status))
}

export function unfinishedDocumentIds(uploads: ReadonlyArray<TrackedUpload>): Array<string> {
	return uploads.flatMap((upload) =>
		upload.stage === "tracked" && !isSettledStatus(upload.status) ? [upload.documentId] : [],
	)
}

function answeredUpload({ key, fileName }: TrackedUpload, outcome: UploadOutcome): TrackedUpload {
	if (outcome.kind !== "accepted") return { key, fileName, stage: "refused", reason: outcome.reason }
	return {
		key,
		fileName,
		stage: "tracked",
		documentId: outcome.documentId,
		title: null,
		status: "processing",
		failureReason: null,
	}
}

export function reduceTrackedUploads(
	uploads: ReadonlyArray<TrackedUpload>,
	event: TrackedUploadEvent,
): ReadonlyArray<TrackedUpload> {
	switch (event.kind) {
		case "submitted":
			return [...event.uploads.map((upload) => ({ ...upload, stage: "uploading" as const })), ...uploads]
		case "answered":
			return uploads.map((upload) => {
				const outcome = event.outcomes[event.keys.indexOf(upload.key)]
				return outcome === undefined ? upload : answeredUpload(upload, outcome)
			})
		case "statuses_received": {
			const records = new Map(event.records.map((record) => [record.documentId, record]))
			return uploads.map((upload) => {
				if (upload.stage !== "tracked") return upload
				const record = records.get(upload.documentId)
				return record === undefined ? upload : { ...upload, ...record }
			})
		}
		case "retried":
			return uploads.map((upload) =>
				upload.stage === "tracked" && upload.documentId === event.documentId
					? { ...upload, status: "processing", failureReason: null }
					: upload,
			)
		case "document_deleted":
			return uploads.filter((upload) => upload.stage !== "tracked" || upload.documentId !== event.documentId)
		case "dismissed":
			return uploads.filter((upload) => upload.key !== event.key)
		case "finished_cleared":
			return uploads.filter((upload) => !isFinishedUpload(upload))
	}
}
