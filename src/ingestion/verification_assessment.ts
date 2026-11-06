import type { documents } from "../database/schema"
import type { DocumentClassification, ExtractedFieldKey } from "./document_classification"

export type VerificationReason = NonNullable<(typeof documents.$inferSelect)["verificationReason"]>

// A required field read with less confidence than this counts as illegible.
const LEGIBILITY_CONFIDENCE_THRESHOLD = 0.5

/** A category that expects an amount, such as Invoice or Receipt, requires it. */
function requiredFieldKeys(categoryExpectedFields: ReadonlyArray<string>): Array<ExtractedFieldKey> {
	return categoryExpectedFields.includes("amount") ? ["amount"] : []
}

/**
 * VISION.md archives every document at once and flags it for verification only when a
 * required field is illegible or when the classifier created a sender, category, or tag.
 * The documents table holds one reason, and an illegible field takes precedence because
 * only the user can supply it. Non-archival email attachments arrive with phase 3.
 */
export function assessVerificationReason(assessment: {
	classification: DocumentClassification
	categoryExpectedFields: ReadonlyArray<string>
	createdTaxonomyRecordCount: number
}): VerificationReason | null {
	const { classification, categoryExpectedFields, createdTaxonomyRecordCount } = assessment
	const illegibleField = requiredFieldKeys(categoryExpectedFields).some((fieldKey) => {
		const field = classification.extractedFields.find((candidate) => candidate.fieldKey === fieldKey)
		return field === undefined || field.confidence < LEGIBILITY_CONFIDENCE_THRESHOLD
	})
	if (classification.documentDate === null || illegibleField) return "illegible_required_field"
	if (createdTaxonomyRecordCount > 0) return "new_taxonomy_record"
	return null
}
