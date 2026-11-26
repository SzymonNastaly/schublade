import { expect, test } from "vitest"
import { fieldExtractionResponseSchema, normalizeClassification } from "./document_classification"

const memberId = "3e5b9d2c-6a47-4f1e-8c2d-91b0a7e4f502"

const response = fieldExtractionResponseSchema.parse({
	answers: {
		document: {
			value: {
				sender: "Stadtwerke Talbrück GmbH",
				title: "  Stadtwerke Talbrück   Electricity Annual Statement 2025-2026 ",
				category: "Invoice",
				amount: 72.089,
				currency: "EUR",
				iban: "de12 9701 1320 0300 4182 25",
				invoice_number: " JA-2026-0381547 ",
				policy_number: null,
				tags: "Utilities, utilities, , –",
			},
			confidence: 0.03,
		},
		document_date: { value: "2026-09-22", confidence: 0.91 },
		due_date: { value: "2026-10-06", confidence: 0.95 },
		renewal_date: { value: "2027-08-31", confidence: 0.18 },
		cancellation_period: { value: 3, confidence: 0.6 },
	},
	usage: { input_tokens: 2457 },
})

test("normalizeClassification converts the answers into archive values and drops typed values below 0.2 confidence", () => {
	expect(normalizeClassification(response.answers, memberId)).toEqual({
		title: "Stadtwerke Talbrück Electricity Annual Statement 2025-2026",
		documentDate: "2026-09-22",
		senderName: "Stadtwerke Talbrück GmbH",
		categoryName: "Invoice",
		personMemberId: memberId,
		tagNames: ["utilities"],
		extractedFields: [
			{ fieldKey: "amount", fieldType: "number", value: 72.09, confidence: null },
			{ fieldKey: "currency", fieldType: "text", value: "EUR", confidence: null },
			{ fieldKey: "due_date", fieldType: "date", value: "2026-10-06", confidence: 0.95 },
			{ fieldKey: "iban", fieldType: "text", value: "DE12970113200300418225", confidence: null },
			{ fieldKey: "invoice_number", fieldType: "text", value: "JA-2026-0381547", confidence: null },
			{ fieldKey: "cancellation_period", fieldType: "text", value: "P3M", confidence: 0.6 },
		],
	})
})
