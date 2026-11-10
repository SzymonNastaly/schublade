import { expect, test } from "vitest"
import { locateReviewStep, verificationEntryKey } from "./verification_entries"
import type { VerificationDocument, VerificationItem } from "../archive/verification_items"

const createdAt = new Date("2026-11-01T08:00:00Z")

const document = (id: string, title: string | null): VerificationDocument => ({
	id,
	status: "archived",
	mimeType: "application/pdf",
	title,
	documentDate: null,
	senderName: null,
})

const failure = (id: string): VerificationItem => ({
	reason: "failed_ingestion",
	createdAt,
	document: document(id, null),
	failureReason: "unreadable_file",
})

const [first, second, third, fourth] = [
	failure("first"),
	failure("second"),
	failure("third"),
	failure("fourth"),
] as const
const entryOrder = ["first", "second", "third", "fourth"]

function reviewOutcome(items: Array<VerificationItem>, requestedKey?: string, skipped: Array<string> = []) {
	const step = locateReviewStep({ items, entryOrder, skippedKeys: new Set(skipped), requestedKey })
	return step.kind === "finished"
		? step
		: { key: verificationEntryKey(step.item), ordinal: step.ordinal, total: step.total, successor: step.successorKey }
}

test("a review moves past a resolved entry to the next one, keeps the count, and comes round to earlier entries last", () => {
	expect([
		reviewOutcome([first, second, third, fourth], "second"),
		reviewOutcome([first, third, fourth], "second"),
		reviewOutcome([first], "fourth"),
	]).toEqual([
		{ key: "second", ordinal: 2, total: 4, successor: "third" },
		{ key: "third", ordinal: 3, total: 4, successor: "fourth" },
		{ key: "first", ordinal: 1, total: 4, successor: undefined },
	])
})

test("a skipped entry is passed over but still opens when requested, and only skipped entries left finish the review", () => {
	expect([
		reviewOutcome([first, second, third, fourth], undefined, ["first"]),
		reviewOutcome([first, second], "first", ["first"]),
		reviewOutcome([first, second], undefined, ["first", "second"]),
		reviewOutcome([]),
	]).toEqual([
		{ key: "second", ordinal: 2, total: 4, successor: "third" },
		{ key: "first", ordinal: 1, total: 4, successor: "second" },
		{ kind: "finished", skippedCount: 2 },
		{ kind: "finished", skippedCount: 0 },
	])
})

test("an entry that arrives during a review joins the end of the count", () => {
	expect(reviewOutcome([failure("arrival"), fourth], "fourth")).toEqual({
		key: "fourth",
		ordinal: 4,
		total: 5,
		successor: "arrival",
	})
})
