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

/** The reason the documents table stores for a document, from its required fields. */
export function assessVerificationReason(state: RequiredFieldState): DocumentVerificationReason | null {
	return illegibleRequiredFields(state).length > 0 ? "illegible_required_field" : null
}

/**
 * VISION.md gives a document one verification reason. A stored reason takes precedence over
 * `new_taxonomy_record`, because only a member can supply an illegible field, while confirming
 * the record resolves every document that refers to it.
 */
export function effectiveVerificationReason(
	storedReason: DocumentVerificationReason | null,
	refersToUnconfirmedRecord: boolean,
): VerificationReason | null {
	return storedReason ?? (refersToUnconfirmedRecord ? "new_taxonomy_record" : null)
}
