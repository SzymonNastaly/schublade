import { expect, test } from "vitest"
import { activeFilters } from "./active_filter_presentation"
import type { ArchiveFacets } from "../archive/document_listing"

const facets: ArchiveFacets = {
	members: [{ id: "member-1", name: "Maja", documentCount: 4 }],
	householdDocumentCount: 2,
	senders: [{ id: "sender-1", name: "Nordkabel", documentCount: 3 }],
	categories: [{ id: "category-1", name: "Rechnung", expectedFields: [], documentCount: 5 }],
	tags: [{ id: "tag-1", name: "tax-2026", documentCount: 1 }],
}

test("every filter is labelled with its value in the order of the controls, and the query is left out", () => {
	expect(
		activeFilters(
			{
				maximumAmount: 100,
				minimumAmount: 12.5,
				tag: "tag-1",
				latestDocumentDate: "2026-12-31",
				earliestDocumentDate: "2026-10-05",
				category: "category-1",
				sender: "sender-1",
				person: "member-1",
				query: "strom",
			},
			facets,
		),
	).toEqual([
		{ criterion: "person", label: "Person: Maja" },
		{ criterion: "sender", label: "Sender: Nordkabel" },
		{ criterion: "category", label: "Category: Rechnung" },
		{ criterion: "earliestDocumentDate", label: "From: 5 Oct 2026" },
		{ criterion: "latestDocumentDate", label: "Until: 31 Dec 2026" },
		{ criterion: "tag", label: "Tag: tax-2026" },
		{ criterion: "minimumAmount", label: "Minimum amount: 12.50" },
		{ criterion: "maximumAmount", label: "Maximum amount: 100.00" },
	])
})

test("the household filter reads as Household", () => {
	expect(activeFilters({ person: "household" }, facets)).toEqual([{ criterion: "person", label: "Person: Household" }])
})

test("a filter on a value no facet holds stays removable", () => {
	expect(activeFilters({ sender: "sender-absent" }, facets)).toEqual([
		{ criterion: "sender", label: "Sender: Not found" },
	])
})
