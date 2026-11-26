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

/** The standard categories that the classification request offers, with the fields the classifier extracts for each. */
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

const typedAnswerSchema = z.object({ value: z.union([z.string(), z.number()]).nullable(), confidence: z.number() })

/** The answers of a Clairic request built by buildFieldExtractionRequest. */
export const fieldExtractionResponseSchema = z.object({
	answers: z.object({
		document: z.object({
			value: z.object({
				sender: z.string().nullable(),
				title: z.string().nullable(),
				category: z.string().nullable(),
				amount: z.number().nullable(),
				currency: z.string().nullable(),
				iban: z.string().nullable(),
				invoice_number: z.string().nullable(),
				policy_number: z.string().nullable(),
				tags: z.string().nullable(),
			}),
		}),
		document_date: typedAnswerSchema,
		due_date: typedAnswerSchema,
		renewal_date: typedAnswerSchema,
		cancellation_period: typedAnswerSchema,
	}),
	usage: z.object({ input_tokens: z.number() }),
})

type FieldExtractionAnswers = z.infer<typeof fieldExtractionResponseSchema>["answers"]

/** The answer of a Clef request built by buildPersonAssignmentRequest. */
export const personAssignmentResponseSchema = z.object({
	answers: z.object({ person: z.object({ choice: z.string() }) }),
	usage: z.object({ input_tokens: z.number() }),
})

type ExtractedField =
	| { fieldKey: ExtractedFieldKey; fieldType: "number"; value: number; confidence: number | null }
	| { fieldKey: ExtractedFieldKey; fieldType: "text" | "date"; value: string; confidence: number | null }

export interface DocumentClassification {
	title: string | null
	documentDate: string | null
	senderName: string | null
	categoryName: string | null
	/** Null assigns the document to the whole household. */
	personMemberId: string | null
	tagNames: Array<string>
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

// Below this confidence, Clairic's typed dates on the test documents were invented, never read.
const MINIMUM_TYPED_CONFIDENCE = 0.2

type TypedAnswer = z.infer<typeof typedAnswerSchema>

function typedValue(answer: TypedAnswer) {
	return answer.value === null || answer.confidence < MINIMUM_TYPED_CONFIDENCE ? null : answer.value
}

/**
 * Clairic reports one confidence for the generated object, the probability of the whole
 * sequence, which says nothing about one field, so generated fields carry none.
 */
function normalizeExtractedFields(answers: FieldExtractionAnswers): Array<ExtractedField> {
	const generated = answers.document.value
	const typed = (answer: TypedAnswer) => ({ value: typedValue(answer), confidence: answer.confidence })
	const cancellationMonths = typedValue(answers.cancellation_period)
	const rawValues: Record<ExtractedFieldKey, { value: string | number | null; confidence: number | null }> = {
		amount: { value: generated.amount, confidence: null },
		currency: { value: generated.currency, confidence: null },
		due_date: typed(answers.due_date),
		iban: { value: generated.iban, confidence: null },
		invoice_number: { value: generated.invoice_number, confidence: null },
		policy_number: { value: generated.policy_number, confidence: null },
		renewal_date: typed(answers.renewal_date),
		cancellation_period: {
			value: cancellationMonths === null ? null : `P${cancellationMonths}M`,
			confidence: answers.cancellation_period.confidence,
		},
	}
	const extractedFields: Array<ExtractedField> = []
	for (const fieldKey of extractedFieldKeys) {
		const { value: rawValue, confidence } = rawValues[fieldKey]
		if (rawValue === null) continue
		const value = normalizeFieldValue(fieldKey, rawValue)
		const fieldConfidence = confidence === null ? null : Math.min(1, Math.max(0, confidence))
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

function normalizeTagNames(tags: string | null): Array<string> {
	const names = (tags ?? "")
		.split(",")
		.map((tag) => normalizeTaxonomyLabel(tag.toLowerCase()))
		.filter((tag) => tag !== null)
	return [...new Set(names)].slice(0, MAXIMUM_TAG_COUNT)
}

/** The classification of Clairic's answers, with the member Clef chose, or null for the household. */
export function normalizeClassification(
	answers: FieldExtractionAnswers,
	personMemberId: string | null,
): DocumentClassification {
	const generated = answers.document.value
	const documentDate = typedValue(answers.document_date)
	return {
		title: generated.title === null ? null : normalizeText(generated.title),
		documentDate: documentDate === null ? null : normalizeCalendarDate(String(documentDate)),
		senderName: generated.sender === null ? null : normalizeTaxonomyLabel(generated.sender),
		categoryName: generated.category === null ? null : normalizeTaxonomyLabel(generated.category),
		personMemberId,
		tagNames: normalizeTagNames(generated.tags),
		extractedFields: normalizeExtractedFields(answers),
	}
}
