import type { documents } from "../database/schema"

/** The one reason a document awaits verification, which the documents table stores. */
export type VerificationReason = NonNullable<(typeof documents.$inferSelect)["verificationReason"]>

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
 *    first would be wasted work.
 * 2. `illegible_required_field`, because only a member can supply the value.
 */
export function assessVerificationReason(
	state: RequiredFieldState & { nonArchival: boolean },
): VerificationReason | null {
	if (state.nonArchival) return "non_archival_attachment"
	return illegibleRequiredFields(state).length > 0 ? "illegible_required_field" : null
}
