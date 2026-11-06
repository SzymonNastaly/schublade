import type { documents } from "../database/schema"

/** A reason that belongs to the document itself, which the documents table stores. */
export type DocumentVerificationReason = NonNullable<(typeof documents.$inferSelect)["verificationReason"]>

/**
 * The one reason a document awaits verification. `new_taxonomy_record` is derived from the
 * unconfirmed sender, category, or tag the document refers to, so confirming the record
 * resolves every document that refers to it.
 */
export type VerificationReason = DocumentVerificationReason | "new_taxonomy_record"

/** The document date always, and the amount when the category expects one, such as Invoice or Receipt. */
export type RequiredFieldKey = "document_date" | "amount"

// A required field read with less confidence than this counts as illegible.
const LEGIBILITY_CONFIDENCE_THRESHOLD = 0.5

interface RequiredFieldState {
	documentDate: string | null
	categoryExpectedFields: ReadonlyArray<string>
	/** A null confidence marks a value a member entered. */
	fields: ReadonlyArray<{ fieldKey: string; confidence: number | null }>
}

export function illegibleRequiredFields(state: RequiredFieldState): Array<RequiredFieldKey> {
	const amountRequired = state.categoryExpectedFields.includes("amount")
	const amount = state.fields.find((field) => field.fieldKey === "amount")
	const amountLegible = amount !== undefined && (amount.confidence ?? 1) >= LEGIBILITY_CONFIDENCE_THRESHOLD
	return [
		...(state.documentDate === null ? (["document_date"] as const) : []),
		...(amountRequired && !amountLegible ? (["amount"] as const) : []),
	]
}

/**
 * The reason the documents table stores for a document. VISION.md gives a document one reason,
 * in this order of precedence:
 *
 * 1. `non_archival_attachment`, because the member deletes such a file, so supplying its fields
 *    or confirming its records first would be wasted work.
 * 2. `illegible_required_field`, because only a member can supply the value.
 * 3. `new_taxonomy_record`, derived in effectiveVerificationReason, because confirming the record
 *    resolves every document that refers to it.
 */
export function assessVerificationReason(
	state: RequiredFieldState & { nonArchival: boolean },
): DocumentVerificationReason | null {
	if (state.nonArchival) return "non_archival_attachment"
	return illegibleRequiredFields(state).length > 0 ? "illegible_required_field" : null
}

/** The reason a document awaits verification: its stored reason, else an unconfirmed record it refers to. */
export function effectiveVerificationReason(
	storedReason: DocumentVerificationReason | null,
	refersToUnconfirmedRecord: boolean,
): VerificationReason | null {
	return storedReason ?? (refersToUnconfirmedRecord ? "new_taxonomy_record" : null)
}
