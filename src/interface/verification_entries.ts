import { documentFailureSentences } from "./document_status_presentation"
import type { VerificationItem } from "../archive/verification_items"
import type { BadgeTone } from "./controls/status_badge"

/** Identifies an entry across reloads of the list, so a review keeps its place as entries resolve. */
export function verificationEntryKey(item: VerificationItem): string {
	return item.document.id
}

interface VerificationEntrySummary {
	badge: { label: string; tone: BadgeTone }
	subject: string
	note: string
}

export function summarizeVerificationEntry(item: VerificationItem): VerificationEntrySummary {
	return {
		badge: { label: "Failed", tone: "failure" },
		subject: item.document.title ?? "Untitled document",
		note: documentFailureSentences[item.failureReason],
	}
}

/** What a review asks about an entry, in the words of the page heading. */
export function describeVerificationQuestion(item: VerificationItem): { question: string; explanation: string } {
	return { question: "This document could not be read", explanation: documentFailureSentences[item.failureReason] }
}

type ReviewStep =
	| { kind: "entry"; item: VerificationItem; ordinal: number; total: number; successorKey: string | undefined }
	| { kind: "finished"; skippedCount: number }

interface ReviewPosition {
	items: ReadonlyArray<VerificationItem>
	/** The keys of the entries when the review began, so a resolved entry keeps its place in the count. */
	entryOrder: ReadonlyArray<string>
	skippedKeys: ReadonlySet<string>
	requestedKey: string | undefined
}

/**
 * The entry a review shows. A requested entry that is still pending shows even after a skip, as
 * when the member goes back to it. Otherwise the review continues after the requested entry's
 * place in the order and comes round to the earlier entries last. Entries that arrive during a
 * review join the end of the order.
 */
export function locateReviewStep({ items, entryOrder, skippedKeys, requestedKey }: ReviewPosition): ReviewStep {
	const pendingEntries = new Map(
		items.map((item) => {
			const key = verificationEntryKey(item)
			return [key, { key, item }]
		}),
	)
	const order = [...new Set([...entryOrder, ...pendingEntries.keys()])]
	const start = requestedKey === undefined ? 0 : Math.max(order.indexOf(requestedKey), 0)
	const open = [...order.slice(start), ...order.slice(0, start)].flatMap((key) => {
		const entry = pendingEntries.get(key)
		return entry === undefined || skippedKeys.has(key) ? [] : [entry]
	})
	const current = (requestedKey === undefined ? undefined : pendingEntries.get(requestedKey)) ?? open[0]
	// Without a requested or open entry, every entry still pending is one the member skipped.
	if (current === undefined) return { kind: "finished", skippedCount: items.length }
	return {
		kind: "entry",
		item: current.item,
		ordinal: order.indexOf(current.key) + 1,
		total: order.length,
		successorKey: open.find(({ key }) => key !== current.key)?.key,
	}
}
