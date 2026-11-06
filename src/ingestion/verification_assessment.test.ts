import { expect, test } from "vitest"
import {
	assessVerificationReason,
	effectiveVerificationReason,
	illegibleRequiredFields,
} from "./verification_assessment"

const receiptFields = ["amount", "currency", "due_date", "iban", "invoice_number"]
const receipt = {
	documentDate: "2026-10-17",
	categoryExpectedFields: receiptFields,
	fields: [{ fieldKey: "amount", confidence: 0.9 }],
}

test("illegibleRequiredFields names a missing date and an amount that is absent or read with low confidence", () => {
	expect([
		illegibleRequiredFields(receipt),
		illegibleRequiredFields({ ...receipt, fields: [{ fieldKey: "amount", confidence: 0.3 }] }),
		illegibleRequiredFields({ ...receipt, documentDate: null, fields: [] }),
		illegibleRequiredFields({ ...receipt, fields: [{ fieldKey: "amount", confidence: null }] }),
		illegibleRequiredFields({ documentDate: null, categoryExpectedFields: [], fields: [] }),
		illegibleRequiredFields({ documentDate: "2026-07-01", categoryExpectedFields: [], fields: [] }),
	]).toEqual([[], ["amount"], ["document_date", "amount"], [], ["document_date"], []])
})

test("an illegible required field takes precedence over a new taxonomy record", () => {
	const illegibleReceipt = { ...receipt, fields: [] }
	expect([
		effectiveVerificationReason(assessVerificationReason(receipt), false),
		effectiveVerificationReason(assessVerificationReason(receipt), true),
		effectiveVerificationReason(assessVerificationReason(illegibleReceipt), false),
		effectiveVerificationReason(assessVerificationReason(illegibleReceipt), true),
	]).toEqual([null, "new_taxonomy_record", "illegible_required_field", "illegible_required_field"])
})
