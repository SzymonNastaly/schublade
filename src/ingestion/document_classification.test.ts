import { expect, test } from "vitest"
import { buildClassificationSchema, normalizeClassification } from "./document_classification"

const memberId = "3e5b9d2c-6a47-4f1e-8c2d-91b0a7e4f502"
const schema = buildClassificationSchema([memberId])

const modelOutput = {
	title: "  Stadtwerke Talbrück   Electricity Annual Statement 2025-2026 ",
	document_date: "22.09.2026",
	sender: "Stadtwerke Talbrück GmbH",
	category: "Invoice",
	person: memberId,
	tags: ["Utilities", "utilities", " ", "–"],
	summary: "An annual electricity statement. It requires a back payment of 72.09 EUR.",
	fields: {
		amount: { value: 72.089, confidence: 1.2 },
		currency: { value: "€", confidence: 0.9 },
		due_date: { value: "2026-10-06", confidence: 0.9 },
		iban: { value: "de12 9701 1320 0300 4182 25", confidence: 0.8 },
		invoice_number: { value: " JA-2026-0381547 ", confidence: 0.9 },
		policy_number: null,
		renewal_date: { value: "31.02.2027", confidence: 0.4 },
		cancellation_period: null,
	},
}

test("the classification schema accepts household members and household only", () => {
	expect([
		schema.safeParse(modelOutput).success,
		schema.safeParse({ ...modelOutput, person: "household" }).success,
		schema.safeParse({ ...modelOutput, person: "Lena Becker" }).success,
	]).toEqual([true, true, false])
})

test("normalizeClassification converts model output into archive values", () => {
	expect(normalizeClassification(schema.parse(modelOutput))).toEqual({
		title: "Stadtwerke Talbrück Electricity Annual Statement 2025-2026",
		documentDate: "2026-09-22",
		senderName: "Stadtwerke Talbrück GmbH",
		categoryName: "Invoice",
		personMemberId: memberId,
		tagNames: ["utilities"],
		summary: "An annual electricity statement. It requires a back payment of 72.09 EUR.",
		extractedFields: [
			{ fieldKey: "amount", fieldType: "number", value: 72.09, confidence: 1 },
			{ fieldKey: "currency", fieldType: "text", value: "EUR", confidence: 0.9 },
			{ fieldKey: "due_date", fieldType: "date", value: "2026-10-06", confidence: 0.9 },
			{ fieldKey: "iban", fieldType: "text", value: "DE12970113200300418225", confidence: 0.8 },
			{ fieldKey: "invoice_number", fieldType: "text", value: "JA-2026-0381547", confidence: 0.9 },
		],
	})
	expect(normalizeClassification(schema.parse({ ...modelOutput, person: "household" })).personMemberId).toBeNull()
})
