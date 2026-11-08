import { expect, test } from "vitest"
import { reduceTrackedUploads, unfinishedDocumentIds } from "./tracked_uploads"
import type { TrackedUpload } from "./tracked_uploads"

const uploadingRows = reduceTrackedUploads([], {
	kind: "submitted",
	uploads: [
		{ key: "first", fileName: "invoice.pdf" },
		{ key: "second", fileName: "notes.txt" },
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
	needsReview: false,
	...overrides,
})

test("an answered request tracks each accepted file by its position and refuses the others", () => {
	const answered = reduceTrackedUploads(uploadingRows, {
		kind: "answered",
		keys: ["first", "second"],
		outcomes: [
			{ kind: "accepted", fileName: "invoice.pdf", documentId: "invoice" },
			{ kind: "rejected", fileName: "notes.txt", reason: "The content of the file is not accepted" },
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
			needsReview: false,
		},
		{
			key: "second",
			fileName: "notes.txt",
			stage: "refused",
			reason: "The content of the file is not accepted",
		},
	])
})

test("a status record updates its row and a retry makes the failed row unfinished again", () => {
	const failed = reduceTrackedUploads([trackedRow("scan", {}), trackedRow("other", {})], {
		kind: "statuses_received",
		records: [
			{ documentId: "scan", title: null, status: "failed", failureReason: "unreadable_file", needsReview: false },
		],
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

test("clearing finished uploads keeps only the uploads still running", () => {
	const uploads: Array<TrackedUpload> = [
		{ key: "sending", fileName: "sending.pdf", stage: "uploading" },
		{ key: "refused", fileName: "refused.txt", stage: "refused", reason: "Too large" },
		trackedRow("archived", { status: "archived" }),
		trackedRow("failed", { status: "failed", failureReason: "processing_error" }),
		trackedRow("extracting", { status: "extracting" }),
	]

	expect(reduceTrackedUploads(uploads, { kind: "finished_cleared" }).map((upload) => upload.key)).toEqual([
		"sending",
		"extracting",
	])
})
