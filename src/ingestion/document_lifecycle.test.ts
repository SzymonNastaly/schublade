import { expect, test } from "vitest"
import { isSettledStatus, predecessorStatuses } from "./document_lifecycle"

test("predecessorStatuses lists the states a document may leave for the target", () => {
	expect({
		extracting: predecessorStatuses("extracting"),
		classifying: predecessorStatuses("classifying"),
		archived: predecessorStatuses("archived"),
		failed: predecessorStatuses("failed"),
		processing: predecessorStatuses("processing"),
	}).toEqual({
		extracting: ["processing"],
		classifying: ["extracting", "recognizing_text"],
		archived: ["classifying"],
		failed: ["processing", "extracting", "recognizing_text", "classifying"],
		processing: ["failed"],
	})
})

test("isSettledStatus holds only for archived, failed, and awaiting_rendering documents", () => {
	const statuses = [
		"awaiting_rendering",
		"processing",
		"extracting",
		"recognizing_text",
		"classifying",
		"archived",
		"failed",
	] as const
	expect(statuses.filter(isSettledStatus)).toEqual(["awaiting_rendering", "archived", "failed"])
})
