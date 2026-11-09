import { expect, test } from "vitest"
import { activeFilters, visibleFacetOptions } from "./active_filter_presentation"
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

test("a collapsed facet panel lists the fullest options and keeps the selected one in view", () => {
	const options = ["A", "B", "C", "D", "E", "F", "G", "H"].map((name, index) => ({
		id: name,
		name,
		documentCount: 8 - index,
	}))
	const { visible, collapsible } = visibleFacetOptions(options, { expanded: false, searchText: "", selected: "H" })
	expect(visible.map((option) => option.name)).toEqual(["A", "B", "C", "D", "E", "F", "H"])
	expect(collapsible).toBe(true)
})

test("an expanded facet panel lists every option whose name holds the search text", () => {
	const options = [
		{ id: "1", name: "Stadtwerke Talbrück", documentCount: 2 },
		{ id: "2", name: "Mühlbach Bank", documentCount: 5 },
	]
	const { visible } = visibleFacetOptions(options, { expanded: true, searchText: "talb", selected: undefined })
	expect(visible.map((option) => option.name)).toEqual(["Stadtwerke Talbrück"])
})
