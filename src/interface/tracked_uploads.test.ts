import { expect, test } from "vitest"
import { reduceTrackedUploads, unfinishedDocumentIds } from "./tracked_uploads"
import type { TrackedUpload } from "./tracked_uploads"

const uploadingRows = reduceTrackedUploads([], {
	kind: "submitted",
	uploads: [
		{ key: "first", fileName: "invoice.pdf" },
		{ key: "second", fileName: "notes.txt" },
		{ key: "third", fileName: "invoice-copy.pdf" },
	],
})

const trackedRow = (key: string, overrides: Partial<Extract<TrackedUpload, { stage: "tracked" }>>): TrackedUpload => ({
	key,
	fileName: `${key}.pdf`,
	stage: "tracked",
	documentId: key,
	title: null,
	status: "processing",
	failureReason: null,
	...overrides,
})

test("an answered request tracks each accepted file by its position, points an already archived one at its document, and refuses the others", () => {
	const answered = reduceTrackedUploads(uploadingRows, {
		kind: "answered",
		keys: ["first", "second", "third"],
		outcomes: [
			{ kind: "accepted", fileName: "invoice.pdf", documentId: "invoice" },
			{ kind: "rejected", fileName: "notes.txt", reason: "The content of the file is not accepted" },
			{ kind: "already_archived", fileName: "invoice-copy.pdf", documentId: "invoice" },
		],
	})

	expect(answered).toEqual([
		{
			key: "first",
			fileName: "invoice.pdf",
			stage: "tracked",
			documentId: "invoice",
			title: null,
			status: "processing",
			failureReason: null,
		},
		{
			key: "second",
			fileName: "notes.txt",
			stage: "refused",
			reason: "The content of the file is not accepted",
		},
		{ key: "third", fileName: "invoice-copy.pdf", stage: "already_archived", documentId: "invoice" },
	])
})

test("a status record updates its row and a retry makes the failed row unfinished again", () => {
	const failed = reduceTrackedUploads([trackedRow("scan", {}), trackedRow("other", {})], {
		kind: "statuses_received",
		records: [{ documentId: "scan", title: null, status: "failed", failureReason: "unreadable_file" }],
	})
	const retried = reduceTrackedUploads(failed, { kind: "retried", documentId: "scan" })

	expect({
		failedRow: failed[0],
		watchedWhileFailed: unfinishedDocumentIds(failed),
		retriedRow: retried[0],
		watchedAfterRetry: unfinishedDocumentIds(retried),
	}).toEqual({
		failedRow: trackedRow("scan", { status: "failed", failureReason: "unreadable_file" }),
		watchedWhileFailed: ["other"],
		retriedRow: trackedRow("scan", {}),
		watchedAfterRetry: ["scan", "other"],
	})
})

test("a deleted document removes every row that links to it, the already archived ones included", () => {
	const uploads: Array<TrackedUpload> = [
		trackedRow("deleted", { status: "failed", failureReason: "processing_error" }),
		{ key: "copy", fileName: "copy.pdf", stage: "already_archived", documentId: "deleted" },
		{ key: "known", fileName: "known.pdf", stage: "already_archived", documentId: "kept" },
		{ key: "refused", fileName: "refused.txt", stage: "refused", reason: "Too large" },
		trackedRow("kept", {}),
	]

	expect(
		reduceTrackedUploads(uploads, { kind: "document_deleted", documentId: "deleted" }).map((upload) => upload.key),
	).toEqual(["known", "refused", "kept"])
})

test("clearing finished uploads keeps only the uploads still running", () => {
	const uploads: Array<TrackedUpload> = [
		{ key: "sending", fileName: "sending.pdf", stage: "uploading" },
		{ key: "refused", fileName: "refused.txt", stage: "refused", reason: "Too large" },
		{ key: "known", fileName: "known.pdf", stage: "already_archived", documentId: "archived" },
		trackedRow("archived", { status: "archived" }),
		trackedRow("failed", { status: "failed", failureReason: "processing_error" }),
		trackedRow("extracting", { status: "extracting" }),
	]

	expect(reduceTrackedUploads(uploads, { kind: "finished_cleared" }).map((upload) => upload.key)).toEqual([
		"sending",
		"extracting",
	])
})
