import type { ArchiveFacets, FacetOption } from "../archive/document_listing"
import type { AuthorizationScope } from "../authorization/caller_authorization"

const selectionLists = ["allowedCategories", "allowedSenders", "allowedTags", "deniedTags"] as const

export type SelectionList = (typeof selectionLists)[number]

/** The scope a consent form grants, or undefined when the form selects nothing usable. */
export function grantedAuthorizationScope(form: FormData): AuthorizationScope | undefined {
	const access = form.get("access")
	if (access === "everything") return { level: "read" }
	if (access !== "selected") return undefined
	const selections = selectionLists.map((list) => [list, [...new Set(form.getAll(list).map(String))]] as const)
	if (selections.every(([, identifiers]) => identifiers.length === 0)) return undefined
	return {
		level: "read",
		...Object.fromEntries(selections.filter(([, identifiers]) => identifiers.length > 0)),
	}
}

function namesOf(identifiers: Array<string> | undefined, options: Array<FacetOption>): string {
	return (identifiers ?? [])
		.map((identifier) => options.find(({ id }) => id === identifier)?.name ?? "Unknown")
		.join(", ")
}

/** The sentence the Settings page shows for a grant. A record that a merge or deletion removed reads Unknown. */
export function describeAuthorizationScope(scope: AuthorizationScope, facets: ArchiveFacets): string {
	const parts = [
		scope.allowedCategories && `Categories: ${namesOf(scope.allowedCategories, facets.categories)}`,
		scope.allowedSenders && `Senders: ${namesOf(scope.allowedSenders, facets.senders)}`,
		scope.allowedTags && `Tags: ${namesOf(scope.allowedTags, facets.tags)}`,
		scope.deniedTags && `Excluding tags: ${namesOf(scope.deniedTags, facets.tags)}`,
	].filter((part) => part !== undefined)
	return parts.length === 0 ? "All documents" : parts.join(". ")
}
