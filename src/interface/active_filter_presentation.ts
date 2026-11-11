import { HOUSEHOLD_PERSON } from "../search/search_index_item"
import { formatAmount, formatDocumentDate } from "./document_formatting"
import type { ArchiveFacets, FacetOption } from "../archive/document_listing"
import type { TaxonomyKind } from "../archive/taxonomy_maintenance"
import type { SearchCriteria } from "../search/search_criteria"

type FilterCriterion = keyof Omit<SearchCriteria, "query">

/** One control of the filter bar. */
export type ArchiveFilter =
	| {
			kind: "option"
			criterion: "person" | TaxonomyKind
			label: string
			/** The plural noun that names the options, such as "senders". */
			noun: string
			options: (facets: ArchiveFacets) => Array<FacetOption>
	  }
	| { kind: "date_range"; label: string }
	| { kind: "amount_range"; label: string }

/** The household members and the whole household, as the Person control offers them. */
function personOptions(facets: ArchiveFacets): Array<FacetOption> {
	return [...facets.members, { id: HOUSEHOLD_PERSON, name: "Household", documentCount: facets.householdDocumentCount }]
}

/** The controls of the filter bar, in their order. */
export const archiveFilters: ReadonlyArray<ArchiveFilter> = [
	{ kind: "option", criterion: "person", label: "Person", noun: "people", options: personOptions },
	{
		kind: "option",
		criterion: "category",
		label: "Category",
		noun: "categories",
		options: (facets) => facets.categories,
	},
	{ kind: "option", criterion: "sender", label: "Sender", noun: "senders", options: (facets) => facets.senders },
	{ kind: "option", criterion: "tag", label: "Tag", noun: "tags", options: (facets) => facets.tags },
	{ kind: "date_range", label: "Date" },
	{ kind: "amount_range", label: "Amount" },
]

/** The criteria each control sets, and so clears. */
function criteriaOfFilter(filter: ArchiveFilter): Array<FilterCriterion> {
	switch (filter.kind) {
		case "option":
			return [filter.criterion]
		case "date_range":
			return ["earliestDocumentDate", "latestDocumentDate"]
		case "amount_range":
			return ["minimumAmount", "maximumAmount"]
	}
}

/** The change that removes every criterion of the given controls, and nothing else. */
export function clearedCriteria(filters: ReadonlyArray<ArchiveFilter>): Partial<SearchCriteria> {
	return Object.fromEntries(filters.flatMap(criteriaOfFilter).map((criterion) => [criterion, undefined]))
}

/** A merged or deleted record, or a hand-written URL, names an identifier no facet holds. */
function optionName(options: Array<FacetOption>, id: string): string {
	return options.find((option) => option.id === id)?.name ?? "Not found"
}

function rangeText(lower: string | undefined, upper: string | undefined, upperWord: string): string | undefined {
	if (lower !== undefined && upper !== undefined) return `${lower} – ${upper}`
	if (lower !== undefined) return `from ${lower}`
	if (upper !== undefined) return `${upperWord} ${upper}`
	return undefined
}

/** The value a control shows while its filter applies, or undefined while it does not. */
export function activeFilterValue(
	filter: ArchiveFilter,
	criteria: SearchCriteria,
	facets: ArchiveFacets,
): string | undefined {
	switch (filter.kind) {
		case "option": {
			const id = criteria[filter.criterion]
			return id === undefined ? undefined : optionName(filter.options(facets), id)
		}
		case "date_range": {
			const { earliestDocumentDate: earliest, latestDocumentDate: latest } = criteria
			return rangeText(
				earliest === undefined ? undefined : formatDocumentDate(earliest),
				latest === undefined ? undefined : formatDocumentDate(latest),
				"until",
			)
		}
		case "amount_range": {
			const { minimumAmount: minimum, maximumAmount: maximum } = criteria
			return rangeText(
				minimum === undefined ? undefined : formatAmount(minimum, undefined),
				maximum === undefined ? undefined : formatAmount(maximum, undefined),
				"up to",
			)
		}
	}
}

/**
 * The controls the bar shows. Person needs a second household member to choose between, and an
 * option control needs options, but a control whose filter applies stays so that it can be cleared.
 */
export function presentedFilters(criteria: SearchCriteria, facets: ArchiveFacets): Array<ArchiveFilter> {
	return archiveFilters.filter((filter) => {
		if (filter.kind !== "option" || activeFilterValue(filter, criteria, facets) !== undefined) return true
		return filter.criterion === "person" ? facets.members.length > 1 : filter.options(facets).length > 0
	})
}

const UNSEARCHED_OPTION_LIMIT = 8

/** Whether a control has so many options that it offers a field to find one by name. */
export function offersOptionSearch(options: ReadonlyArray<FacetOption>): boolean {
	return options.length > UNSEARCHED_OPTION_LIMIT
}

/** The options whose name holds the search text, those with the most documents first, then by name. */
export function rankedOptions(options: ReadonlyArray<FacetOption>, searchText: string): Array<FacetOption> {
	const needle = searchText.trim().toLocaleLowerCase()
	return options
		.filter((option) => option.name.toLocaleLowerCase().includes(needle))
		.sort((first, second) => second.documentCount - first.documentCount || first.name.localeCompare(second.name))
}

/** Each kind is also the criterion that filters by it, so `{ [kind]: id }` changes that filter. */
export const taxonomyKindPresentations: Record<TaxonomyKind, { label: string; heading: string }> = {
	sender: { label: "sender", heading: "Sender" },
	category: { label: "category", heading: "Category" },
	tag: { label: "tag", heading: "Tag" },
}

/** A sender, category, or tag the archive is filtered by. */
export interface FilteredTaxonomyRecord {
	kind: TaxonomyKind
	id: string
	name: string
	/** Archived documents only, as the facet counts them. */
	documentCount: number
	/** Every other record of the same kind. */
	mergeTargets: Array<FacetOption>
}

/**
 * The sender, category, or tag that a control filters by. Person has no record to maintain, and a
 * filter whose identifier no facet holds, as after a merge or deletion elsewhere, has none either.
 */
export function filteredTaxonomyRecord(
	filter: ArchiveFilter,
	criteria: SearchCriteria,
	facets: ArchiveFacets,
): FilteredTaxonomyRecord | undefined {
	if (filter.kind !== "option" || filter.criterion === "person") return undefined
	const kind = filter.criterion
	const options = filter.options(facets)
	const record = options.find((option) => option.id === criteria[kind])
	if (record === undefined) return undefined
	return {
		kind,
		id: record.id,
		name: record.name,
		documentCount: record.documentCount,
		mergeTargets: options
			.filter((option) => option.id !== record.id)
			.map(({ id, name, documentCount }) => ({ id, name, documentCount })),
	}
}
