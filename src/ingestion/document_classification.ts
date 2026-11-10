import { z } from "zod"
import { normalizeTaxonomyName } from "./taxonomy_resolution"

type ExtractedFieldType = "number" | "text" | "date"

export const extractedFieldTypes = {
	amount: "number",
	currency: "text",
	due_date: "date",
	iban: "text",
	invoice_number: "text",
	policy_number: "text",
	renewal_date: "date",
	cancellation_period: "text",
} as const satisfies Record<string, ExtractedFieldType>

export type ExtractedFieldKey = keyof typeof extractedFieldTypes

export const extractedFieldKeys = Object.keys(extractedFieldTypes) as Array<ExtractedFieldKey>

const invoiceFields: ReadonlyArray<ExtractedFieldKey> = ["amount", "currency", "due_date", "iban", "invoice_number"]
const contractFields: ReadonlyArray<ExtractedFieldKey> = ["policy_number", "renewal_date", "cancellation_period"]

/** The categories VISION.md names, with the fields the classifier extracts for each. */
export const standardCategories: ReadonlyArray<{ name: string; expectedFields: ReadonlyArray<ExtractedFieldKey> }> = [
	{ name: "Invoice", expectedFields: invoiceFields },
	{ name: "Receipt", expectedFields: invoiceFields },
	{ name: "Contract", expectedFields: contractFields },
	{ name: "Insurance", expectedFields: contractFields },
	{ name: "Tax Notice", expectedFields: [] },
	{ name: "Bank Statement", expectedFields: [] },
	{ name: "Medical", expectedFields: [] },
	{ name: "Official Identification", expectedFields: [] },
]

/** The standard category that a category name denotes, if any. */
export function findStandardCategory(normalizedName: string) {
	return standardCategories.find((category) => normalizeTaxonomyName(category.name) === normalizedName)
}

const confidence = z.number().describe("Probability from 0 to 1 that the value is printed and read correctly")

function fieldValue<TValue extends z.ZodType>(value: TValue, description: string) {
	return z.object({ value, confidence }).nullable().describe(`${description} Null when the document does not print it.`)
}

const calendarDate = "Calendar date in the form YYYY-MM-DD."

/**
 * The structured output the classification model returns. The person field accepts only
 * the identifiers of the household members in D1 and `household`, so the model cannot
 * invent a member.
 */
export function buildClassificationSchema(memberIds: ReadonlyArray<string>) {
	const people: [string, ...Array<string>] = ["household", ...memberIds]
	return z.object({
		title: z.string().describe("English title: sender without legal form, document type, and period or subject"),
		document_date: z.string().nullable().describe(`Issue date printed on the document. ${calendarDate}`),
		sender: z.string().describe("Organization, authority, or person that issued the document"),
		category: z.string().describe("One primary category"),
		person: z.enum(people).describe("Identifier of the household member the document concerns, or household"),
		tags: z.array(z.string()).describe("Zero to three lowercase cross-cutting labels such as tax-2026"),
		summary: z.string().describe("Two English sentences: what the document is, and what it records or requires"),
		fields: z.object({
			amount: fieldValue(
				z.number(),
				"Final total as a decimal number: the amount to pay, paid, or refunded, such as Gesamtbetrag, Rechnungsbetrag, Summe, Nachzahlung, or Erstattung.",
			),
			currency: fieldValue(z.string(), "ISO 4217 code of the amount, such as EUR for € or USD for $."),
			due_date: fieldValue(z.string(), `Date by which the amount must be paid, such as zahlbar bis. ${calendarDate}`),
			iban: fieldValue(z.string(), "IBAN printed on the document, without spaces."),
			invoice_number: fieldValue(
				z.string(),
				"Invoice, receipt, or transaction number, such as Rechnungsnummer or Bon-Nr.",
			),
			policy_number: fieldValue(z.string(), "Contract or insurance policy number, such as Vertragsnummer."),
			renewal_date: fieldValue(z.string(), `Date the contract or policy next renews or ends. ${calendarDate}`),
			cancellation_period: fieldValue(
				z.string(),
				"Notice period (Kündigungsfrist) as an ISO 8601 duration such as P3M.",
			),
		} satisfies Record<ExtractedFieldKey, z.ZodType>),
	})
}

type ClassificationOutput = z.infer<ReturnType<typeof buildClassificationSchema>>

type ExtractedField =
	| { fieldKey: ExtractedFieldKey; fieldType: "number"; value: number; confidence: number }
	| { fieldKey: ExtractedFieldKey; fieldType: "text" | "date"; value: string; confidence: number }

export interface DocumentClassification {
	title: string | null
	documentDate: string | null
	senderName: string | null
	categoryName: string | null
	/** Null assigns the document to the whole household. */
	personMemberId: string | null
	tagNames: Array<string>
	summary: string | null
	extractedFields: Array<ExtractedField>
}

export const MAXIMUM_TAG_COUNT = 5

const currencySymbols: Record<string, string> = { "€": "EUR", $: "USD", "£": "GBP" }

function normalizeText(value: string): string | null {
	const text = value.replace(/\s+/g, " ").trim()
	return text === "" ? null : text
}

/** Accepts an ISO 8601 calendar date or a German `DD.MM.YYYY` date and returns ISO 8601. */
function normalizeCalendarDate(value: string): string | null {
	const text = value.trim()
	const isoMatch = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text)
	const germanMatch = /^(\d{1,2})\.(\d{1,2})\.(\d{4})$/.exec(text)
	const [year, month, day] = isoMatch
		? [isoMatch[1], isoMatch[2], isoMatch[3]].map(Number)
		: germanMatch
			? [germanMatch[3], germanMatch[2], germanMatch[1]].map(Number)
			: []
	if (year === undefined || month === undefined || day === undefined) return null
	const date = new Date(Date.UTC(year, month - 1, day))
	if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null
	return date.toISOString().slice(0, 10)
}

function normalizeCurrencyCode(value: string): string | null {
	const text = value.trim()
	const code = currencySymbols[text] ?? text.toUpperCase()
	return /^[A-Z]{3}$/.test(code) ? code : null
}

/** The archive value of a field, or null when the value does not fit the field's type. */
export function normalizeFieldValue(fieldKey: ExtractedFieldKey, value: string | number): string | number | null {
	if (extractedFieldTypes[fieldKey] === "number") {
		return typeof value === "number" && Number.isFinite(value) ? Math.round(value * 100) / 100 : null
	}
	const text = String(value)
	switch (fieldKey) {
		case "currency":
			return normalizeCurrencyCode(text)
		case "iban":
			return normalizeText(text.replace(/\s+/g, "").toUpperCase())
		default:
			return extractedFieldTypes[fieldKey] === "date" ? normalizeCalendarDate(text) : normalizeText(text)
	}
}

function normalizeExtractedFields(fields: ClassificationOutput["fields"]): Array<ExtractedField> {
	const extractedFields: Array<ExtractedField> = []
	for (const fieldKey of extractedFieldKeys) {
		const extracted = fields[fieldKey]
		if (extracted === null) continue
		const value = normalizeFieldValue(fieldKey, extracted.value)
		const fieldConfidence = Math.min(1, Math.max(0, extracted.confidence))
		if (typeof value === "number") {
			extractedFields.push({ fieldKey, fieldType: "number", value, confidence: fieldConfidence })
		} else if (typeof value === "string") {
			const fieldType = extractedFieldTypes[fieldKey] === "date" ? "date" : "text"
			extractedFields.push({ fieldKey, fieldType, value, confidence: fieldConfidence })
		}
	}
	return extractedFields
}

/** A name without a letter or digit cannot identify a sender, category, or tag. */
function normalizeTaxonomyLabel(value: string): string | null {
	const text = normalizeText(value)
	return text === null || normalizeTaxonomyName(text) === "" ? null : text
}

function normalizeTagNames(tags: Array<string>): Array<string> {
	const names = tags.map((tag) => normalizeTaxonomyLabel(tag.toLowerCase())).filter((tag) => tag !== null)
	return [...new Set(names)].slice(0, MAXIMUM_TAG_COUNT)
}

export function normalizeClassification(output: ClassificationOutput): DocumentClassification {
	return {
		title: normalizeText(output.title),
		documentDate: output.document_date === null ? null : normalizeCalendarDate(output.document_date),
		senderName: normalizeTaxonomyLabel(output.sender),
		categoryName: normalizeTaxonomyLabel(output.category),
		personMemberId: output.person === "household" ? null : output.person,
		tagNames: normalizeTagNames(output.tags),
		summary: normalizeText(output.summary),
		extractedFields: normalizeExtractedFields(output.fields),
	}
}
