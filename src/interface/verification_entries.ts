import { normalizeTaxonomyName } from "../ingestion/taxonomy_resolution"
import { documentFailureSentences } from "./document_status_presentation"
import type { VerificationDocument, VerificationItem } from "../archive/verification_items"
import type { BadgeTone } from "./controls/status_badge"
import type { RequiredFieldKey } from "../ingestion/verification_assessment"

/** Identifies an entry across reloads of the list, so a review keeps its place as entries resolve. */
export function verificationEntryKey(item: VerificationItem): string {
	return item.reason === "new_taxonomy_record" ? `${item.record.kind}-${item.record.id}` : item.document.id
}

export function documentCountLabel(count: number): string {
	if (count === 0) return "No documents"
	return count === 1 ? "1 document" : `${count} documents`
}

export const requiredFieldLabels: Record<RequiredFieldKey, string> = {
	document_date: "Document date",
	amount: "Amount",
}

interface VerificationEntrySummary {
	badge: { label: string; tone: BadgeTone }
	subject: string
	note: string
}

export function summarizeVerificationEntry(item: VerificationItem): VerificationEntrySummary {
	switch (item.reason) {
		case "new_taxonomy_record":
			return {
				badge: { label: `New ${item.record.kind}`, tone: "verification" },
				subject: item.record.name,
				note: documentCountLabel(item.documents.length),
			}
		case "illegible_required_field":
			return {
				badge: { label: "Unreadable field", tone: "verification" },
				subject: item.document.title ?? "Untitled document",
				note: item.illegibleFields
					.map(({ fieldKey, value }) => `${requiredFieldLabels[fieldKey]} is ${value === null ? "missing" : "unclear"}`)
					.join(" · "),
			}
		case "non_archival_attachment":
			return {
				badge: { label: "Non-archival attachment", tone: "verification" },
				subject: item.document.title ?? "Untitled document",
				note: "Looks like boilerplate",
			}
		case "failed_ingestion":
			return {
				badge: { label: "Failed", tone: "failure" },
				subject: item.document.title ?? "Untitled document",
				note: documentFailureSentences[item.failureReason],
			}
	}
}

/** The document a review shows for an entry. A record shows the newest document that refers to it, if any does. */
export function reviewedDocument(item: VerificationItem): VerificationDocument | undefined {
	return item.reason === "new_taxonomy_record" ? item.documents[0] : item.document
}

export interface NewSenderSelection {
	senders: Array<{ id: string; name: string; documentCount: number }>
	unknownSenderLeftOut: boolean
}

/** The new senders a member can confirm together. The classifier invents the name Unknown for unreadable documents. */
export function selectNewSenders(items: ReadonlyArray<VerificationItem>): NewSenderSelection {
	const newSenders = items.flatMap((item) =>
		item.reason === "new_taxonomy_record" && item.record.kind === "sender"
			? [{ id: item.record.id, name: item.record.name, documentCount: item.documents.length }]
			: [],
	)
	const isUnknown = ({ name }: { name: string }) => normalizeTaxonomyName(name) === "unknown"
	return {
		senders: newSenders.filter((sender) => !isUnknown(sender)),
		unknownSenderLeftOut: newSenders.some(isUnknown),
	}
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
