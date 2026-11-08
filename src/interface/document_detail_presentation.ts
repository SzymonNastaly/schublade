import { extractedFieldKeys, extractedFieldTypes, findStandardCategory } from "../ingestion/document_classification"
import { normalizeTaxonomyName } from "../ingestion/taxonomy_resolution"
import { HOUSEHOLD_PERSON } from "../search/search_index_item"
import { formatAmount, formatDocumentDate, formatIban, formatPeriod } from "./document_formatting"
import type { ArchiveFacets, ListedDocument } from "../archive/document_listing"
import type { ExtractedFieldKey } from "../ingestion/document_classification"
import type { SearchCriteria } from "../search/search_criteria"

export const fieldLabels: Record<ExtractedFieldKey, string> = {
	amount: "Amount",
	currency: "Currency",
	due_date: "Due date",
	iban: "IBAN",
	invoice_number: "Invoice number",
	policy_number: "Policy number",
	renewal_date: "Renewal date",
	cancellation_period: "Cancellation period",
}

const textFieldFormats: Partial<Record<ExtractedFieldKey, (text: string) => string>> = {
	iban: formatIban,
	cancellation_period: formatPeriod,
}

type ArchiveFilter = Pick<SearchCriteria, "person" | "sender" | "category" | "tag">

interface DetailValue {
	text: string
	/** The archive filter a link on this value opens. Absent for a value that has no filter. */
	filter?: ArchiveFilter
}

interface DetailRow {
	label: string
	values: Array<DetailValue>
}

function facetValues(
	name: string | null,
	options: ReadonlyArray<{ id: string; name: string }>,
	filterFor: (id: string) => ArchiveFilter,
): Array<DetailValue> {
	if (name === null) return []
	const option = options.find((candidate) => candidate.name === name)
	return [option === undefined ? { text: name } : { text: name, filter: filterFor(option.id) }]
}

function personValues(document: ListedDocument, facets: ArchiveFacets): Array<DetailValue> {
	if (document.status === "archived" && document.personMemberId === null) {
		return [{ text: "Household", filter: { person: HOUSEHOLD_PERSON } }]
	}
	return facetValues(document.personName, facets.members, (person) => ({ person }))
}

function extractedFieldRows(fields: ListedDocument["fields"]): Array<DetailRow> {
	const valueOf = (fieldKey: ExtractedFieldKey) => fields.find((field) => field.fieldKey === fieldKey)?.value ?? null
	const amount = valueOf("amount")
	const currency = valueOf("currency")
	return extractedFieldKeys.flatMap((fieldKey) => {
		const value = valueOf(fieldKey)
		if (value === null || (fieldKey === "currency" && typeof amount === "number")) return []
		const text =
			fieldKey === "amount" && typeof value === "number"
				? formatAmount(value, typeof currency === "string" ? currency : undefined)
				: extractedFieldTypes[fieldKey] === "date"
					? formatDocumentDate(String(value))
					: (textFieldFormats[fieldKey]?.(String(value)) ?? String(value))
		return [{ label: fieldLabels[fieldKey], values: [{ text }] }]
	})
}

/** The filled-in details of a document in reading order. A name the facets do not hold stays plain text. */
export function documentDetailRows(document: ListedDocument, facets: ArchiveFacets): Array<DetailRow> {
	const rows: Array<DetailRow> = [
		{
			label: "Date",
			values: document.documentDate === null ? [] : [{ text: formatDocumentDate(document.documentDate) }],
		},
		{ label: "Sender", values: facetValues(document.senderName, facets.senders, (sender) => ({ sender })) },
		{ label: "Category", values: facetValues(document.categoryName, facets.categories, (category) => ({ category })) },
		{ label: "Person", values: personValues(document, facets) },
		{ label: "Tags", values: document.tagNames.flatMap((name) => facetValues(name, facets.tags, (tag) => ({ tag }))) },
		...extractedFieldRows(document.fields),
	]
	return rows.filter((row) => row.values.length > 0)
}

/**
 * The extracted fields the revision form offers: those the named category expects, and those with
 * a value in any of the given field states. Passing the state at the start of editing as well as
 * the current one keeps an input in place while its value is cleared.
 */
export function offeredFieldKeys(
	categoryName: string,
	categories: ArchiveFacets["categories"],
	fieldStates: ReadonlyArray<Record<ExtractedFieldKey, string>>,
): Array<ExtractedFieldKey> {
	const normalizedName = normalizeTaxonomyName(categoryName)
	const expectedFields: ReadonlyArray<string> =
		categories.find((category) => normalizeTaxonomyName(category.name) === normalizedName)?.expectedFields ??
		findStandardCategory(normalizedName)?.expectedFields ??
		[]
	return extractedFieldKeys.filter(
		(fieldKey) => expectedFields.includes(fieldKey) || fieldStates.some((fields) => fields[fieldKey] !== ""),
	)
}
