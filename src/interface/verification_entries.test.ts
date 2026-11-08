import { expect, test } from "vitest"
import {
	locateReviewStep,
	selectNewSenders,
	summarizeVerificationEntry,
	verificationEntryKey,
} from "./verification_entries"
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

const newSender = (id: string, name: string, documentIds: Array<string> = []): VerificationItem => ({
	reason: "new_taxonomy_record",
	createdAt,
	record: { kind: "sender", id, name },
	documents: documentIds.map((documentId) => document(documentId, null)),
})

const attachment = (id: string): VerificationItem => ({
	reason: "non_archival_attachment",
	createdAt,
	document: document(id, "General Terms"),
})

const [first, second, third, fourth] = [
	newSender("first", "Nordkabel"),
	attachment("second"),
	newSender("third", "Allianz SE"),
	attachment("fourth"),
] as const
const entryOrder = ["sender-first", "second", "sender-third", "fourth"]

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
		{ key: "second", ordinal: 2, total: 4, successor: "sender-third" },
		{ key: "sender-third", ordinal: 3, total: 4, successor: "fourth" },
		{ key: "sender-first", ordinal: 1, total: 4, successor: undefined },
	])
})

test("a skipped entry is passed over but still opens when requested, and only skipped entries left finish the review", () => {
	expect([
		reviewOutcome([first, second, third, fourth], undefined, ["sender-first"]),
		reviewOutcome([first, second], "sender-first", ["sender-first"]),
		reviewOutcome([first, second], undefined, ["sender-first", "second"]),
		reviewOutcome([]),
	]).toEqual([
		{ key: "second", ordinal: 2, total: 4, successor: "sender-third" },
		{ key: "sender-first", ordinal: 1, total: 4, successor: "second" },
		{ kind: "finished", skippedCount: 2 },
		{ kind: "finished", skippedCount: 0 },
	])
})

test("an entry that arrives during a review joins the end of the count", () => {
	expect(reviewOutcome([newSender("arrival", "Werkhof"), fourth], "fourth")).toEqual({
		key: "fourth",
		ordinal: 4,
		total: 5,
		successor: "sender-arrival",
	})
})

test("selectNewSenders leaves out only the sender the classifier names Unknown, however it is written", () => {
	const items = [
		newSender("nordkabel", "Nordkabel", ["one", "two"]),
		newSender("unknown", " UNKNOWN."),
		attachment("three"),
	]

	expect([selectNewSenders(items), selectNewSenders([items[0] as VerificationItem])]).toEqual([
		{ senders: [{ id: "nordkabel", name: "Nordkabel", documentCount: 2 }], unknownSenderLeftOut: true },
		{ senders: [{ id: "nordkabel", name: "Nordkabel", documentCount: 2 }], unknownSenderLeftOut: false },
	])
})

test("an unreadable field entry notes each field as missing when it has no value and as unclear when it has one", () => {
	const item: VerificationItem = {
		reason: "illegible_required_field",
		createdAt,
		document: document("receipt", null),
		illegibleFields: [
			{ fieldKey: "document_date", value: null },
			{ fieldKey: "amount", value: 75.49 },
		],
	}

	expect(summarizeVerificationEntry(item)).toEqual({
		badge: { label: "Unreadable field", variant: "warning" },
		subject: "Untitled document",
		note: "Document date is missing · Amount is unclear",
	})
})
