import { HOUSEHOLD_PERSON } from "../search/search_index_item"
import { formatAmount, formatDocumentDate } from "./document_formatting"
import type { ArchiveFacets, FacetOption } from "../archive/document_listing"
import type { SearchCriteria } from "../search/search_criteria"

type FilterValues = Required<Omit<SearchCriteria, "query">>
type FilterCriterion = keyof FilterValues

/** The household members and the whole household, as the Person control offers them. */
export function personOptions(facets: ArchiveFacets): Array<FacetOption> {
	return [...facets.members, { id: HOUSEHOLD_PERSON, name: "Household", documentCount: facets.householdDocumentCount }]
}

/** A merged or deleted record, or a hand-written URL, names an identifier no facet holds. */
function optionName(options: Array<FacetOption>, id: string): string {
	return options.find((option) => option.id === id)?.name ?? "Not found"
}

const filterLabels: {
	[TCriterion in FilterCriterion]: (value: FilterValues[TCriterion], facets: ArchiveFacets) => string
} = {
	person: (person, facets) => `Person: ${optionName(personOptions(facets), person)}`,
	sender: (sender, facets) => `Sender: ${optionName(facets.senders, sender)}`,
	category: (category, facets) => `Category: ${optionName(facets.categories, category)}`,
	earliestDocumentDate: (date) => `From: ${formatDocumentDate(date)}`,
	latestDocumentDate: (date) => `Until: ${formatDocumentDate(date)}`,
	tag: (tag, facets) => `Tag: ${optionName(facets.tags, tag)}`,
	minimumAmount: (amount) => `Minimum amount: ${formatAmount(amount, undefined)}`,
	maximumAmount: (amount) => `Maximum amount: ${formatAmount(amount, undefined)}`,
}

const filterCriteria = Object.keys(filterLabels) as Array<FilterCriterion>

function filterLabel<TCriterion extends FilterCriterion>(
	criterion: TCriterion,
	value: FilterValues[TCriterion],
	facets: ArchiveFacets,
): string {
	return filterLabels[criterion](value, facets)
}

export interface ActiveFilter {
	criterion: FilterCriterion
	label: string
}

/** One entry for each filter the criteria apply, in the order of the controls. */
export function activeFilters(criteria: SearchCriteria, facets: ArchiveFacets): Array<ActiveFilter> {
	return filterCriteria.flatMap((criterion) => {
		const value = criteria[criterion]
		return value === undefined ? [] : [{ criterion, label: filterLabel(criterion, value, facets) }]
	})
}

const COLLAPSED_OPTION_COUNT = 6

interface FacetPanelState {
	expanded: boolean
	searchText: string
	selected: string | undefined
}

/**
 * The options a panel lists, those with the most documents first. A collapsed panel keeps the
 * selected option in view even when it would not have made the cut.
 */
export function visibleFacetOptions(
	options: ReadonlyArray<FacetOption>,
	{ expanded, searchText, selected }: FacetPanelState,
): { visible: Array<FacetOption>; collapsible: boolean } {
	const ranked = [...options].sort(
		(first, second) => second.documentCount - first.documentCount || first.name.localeCompare(second.name),
	)
	const collapsible = ranked.length > COLLAPSED_OPTION_COUNT
	if (expanded) {
		const needle = searchText.trim().toLocaleLowerCase()
		return { visible: ranked.filter((option) => option.name.toLocaleLowerCase().includes(needle)), collapsible }
	}
	const leading = ranked.slice(0, COLLAPSED_OPTION_COUNT)
	const selectedOption = ranked.find((option) => option.id === selected)
	const selectedIsHidden = selectedOption !== undefined && !leading.includes(selectedOption)
	return { visible: selectedIsHidden ? [...leading, selectedOption] : leading, collapsible }
}
