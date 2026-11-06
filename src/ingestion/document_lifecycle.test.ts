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
		processing: [],
	})
})

test("isSettledStatus holds only for archived and failed documents", () => {
	const statuses = ["processing", "extracting", "recognizing_text", "classifying", "archived", "failed"] as const
	expect(statuses.filter(isSettledStatus)).toEqual(["archived", "failed"])
})
