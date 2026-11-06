import { expect, test } from "vitest"
import { assessVerificationReason } from "./verification_assessment"
import type { DocumentClassification } from "./document_classification"

const receipt: DocumentClassification = {
	title: "Werkhof Baumarkt Receipt October 2026",
	documentDate: "2026-10-17",
	senderName: "Werkhof Baumarkt GmbH",
	categoryName: "Receipt",
	personMemberId: null,
	tagNames: [],
	summary: null,
	extractedFields: [{ fieldKey: "amount", fieldType: "number", value: 75.49, confidence: 0.9 }],
}
const receiptFields = ["amount", "currency", "due_date", "iban", "invoice_number"]

test("assessVerificationReason flags an illegible required field before a new taxonomy record", () => {
	expect([
		assessVerificationReason({
			classification: receipt,
			categoryExpectedFields: receiptFields,
			createdTaxonomyRecordCount: 0,
		}),
		assessVerificationReason({
			classification: receipt,
			categoryExpectedFields: receiptFields,
			createdTaxonomyRecordCount: 1,
		}),
		assessVerificationReason({
			classification: {
				...receipt,
				extractedFields: [{ fieldKey: "amount", fieldType: "number", value: 75.49, confidence: 0.3 }],
			},
			categoryExpectedFields: receiptFields,
			createdTaxonomyRecordCount: 1,
		}),
		assessVerificationReason({
			classification: { ...receipt, extractedFields: [] },
			categoryExpectedFields: [],
			createdTaxonomyRecordCount: 0,
		}),
		assessVerificationReason({
			classification: { ...receipt, documentDate: null },
			categoryExpectedFields: [],
			createdTaxonomyRecordCount: 0,
		}),
	]).toEqual([null, "new_taxonomy_record", "illegible_required_field", null, "illegible_required_field"])
})
