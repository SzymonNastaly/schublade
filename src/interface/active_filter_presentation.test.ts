import { expect, test } from "vitest"
import {
	activeFilterValue,
	archiveFilters,
	clearedCriteria,
	filteredTaxonomyRecord,
	offersOptionSearch,
	presentedFilters,
	rankedOptions,
} from "./active_filter_presentation"
import type { ArchiveFilter } from "./active_filter_presentation"
import type { ArchiveFacets } from "../archive/document_listing"
import type { SearchCriteria } from "../search/search_criteria"

const facets: ArchiveFacets = {
	members: [
		{ id: "member-1", name: "Maja", documentCount: 4 },
		{ id: "member-2", name: "Jonas", documentCount: 1 },
	],
	householdDocumentCount: 2,
	senders: [{ id: "sender-1", name: "Nordkabel", documentCount: 3 }],
	categories: [{ id: "category-1", name: "Rechnung", expectedFields: [], documentCount: 5 }],
	tags: [{ id: "tag-1", name: "tax-2026", documentCount: 1 }],
}

function control(label: string): ArchiveFilter {
	const filter = archiveFilters.find((candidate) => candidate.label === label)
	if (filter === undefined) throw new Error(`The filter bar has no ${label} control`)
	return filter
}

function controlValues(criteria: SearchCriteria, archiveFacets: ArchiveFacets = facets) {
	return archiveFilters.map((filter) => [filter.label, activeFilterValue(filter, criteria, archiveFacets)])
}

test("each control shows the value of its filter, and the query belongs to none", () => {
	expect(
		controlValues({
			maximumAmount: 100,
			minimumAmount: 12.5,
			tag: "tag-1",
			latestDocumentDate: "2026-12-31",
			earliestDocumentDate: "2026-10-05",
			category: "category-1",
			sender: "sender-1",
			person: "household",
			query: "strom",
		}),
	).toEqual([
		["Person", "Household"],
		["Category", "Rechnung"],
		["Sender", "Nordkabel"],
		["Tag", "tax-2026"],
		["Date", "5 Oct 2026 – 31 Dec 2026"],
		["Amount", "12.50 – 100.00"],
	])
})

test("a range with one bound names that bound", () => {
	expect(controlValues({ earliestDocumentDate: "2026-10-05", maximumAmount: 100 }).slice(4)).toEqual([
		["Date", "from 5 Oct 2026"],
		["Amount", "up to 100.00"],
	])
	expect(controlValues({ latestDocumentDate: "2026-12-31", minimumAmount: 12.5 }).slice(4)).toEqual([
		["Date", "until 31 Dec 2026"],
		["Amount", "from 12.50"],
	])
})

test("a filter on a value no facet holds reads Not found", () => {
	expect(controlValues({ sender: "sender-absent" })[2]).toEqual(["Sender", "Not found"])
})

test("clearing a range control removes both of its bounds, and clearing every control keeps the query", () => {
	expect(clearedCriteria([control("Date")])).toEqual({ earliestDocumentDate: undefined, latestDocumentDate: undefined })
	expect(clearedCriteria(archiveFilters)).toEqual({
		person: undefined,
		category: undefined,
		sender: undefined,
		tag: undefined,
		earliestDocumentDate: undefined,
		latestDocumentDate: undefined,
		minimumAmount: undefined,
		maximumAmount: undefined,
	})
})

test("the bar leaves out Person for a household of one and controls without options, unless their filter applies", () => {
	const sparseFacets: ArchiveFacets = {
		...facets,
		members: [{ id: "member-1", name: "Maja", documentCount: 4 }],
		tags: [],
	}
	expect(presentedFilters({}, sparseFacets).map((filter) => filter.label)).toEqual([
		"Category",
		"Sender",
		"Date",
		"Amount",
	])
	expect(presentedFilters({ person: "member-1", tag: "tag-1" }, sparseFacets).map((filter) => filter.label)).toEqual([
		"Person",
		"Category",
		"Sender",
		"Tag",
		"Date",
		"Amount",
	])
})

test("options are found by any part of their name and ranked by document count, then by name", () => {
	const options = [
		{ id: "1", name: "Stadtwerke Talbrück", documentCount: 2 },
		{ id: "2", name: "Mühlbach Bank", documentCount: 5 },
		{ id: "3", name: "Stadt Talbrück", documentCount: 2 },
	]
	expect(rankedOptions(options, "").map((option) => option.name)).toEqual([
		"Mühlbach Bank",
		"Stadt Talbrück",
		"Stadtwerke Talbrück",
	])
	expect(rankedOptions(options, " TALB ").map((option) => option.name)).toEqual([
		"Stadt Talbrück",
		"Stadtwerke Talbrück",
	])
})

test("a control offers a search field from nine options upward", () => {
	const options = Array.from({ length: 9 }, (_, index) => ({ id: `${index}`, name: `${index}`, documentCount: 1 }))
	expect(offersOptionSearch(options.slice(0, 8))).toBe(false)
	expect(offersOptionSearch(options)).toBe(true)
})

test("a sender filter names its record with the other senders to merge into", () => {
	const fullerFacets: ArchiveFacets = {
		...facets,
		senders: [
			{ id: "sender-1", name: "Nordkabel", documentCount: 3 },
			{ id: "sender-2", name: "Nordkabel GmbH", documentCount: 0 },
		],
	}
	expect(filteredTaxonomyRecord(control("Sender"), { sender: "sender-2" }, fullerFacets)).toEqual({
		kind: "sender",
		id: "sender-2",
		name: "Nordkabel GmbH",
		documentCount: 0,
		mergeTargets: [{ id: "sender-1", name: "Nordkabel", documentCount: 3 }],
	})
})

test("a person filter, and a filter whose identifier no facet holds, name no record", () => {
	expect(filteredTaxonomyRecord(control("Person"), { person: "member-1" }, facets)).toBeUndefined()
	expect(filteredTaxonomyRecord(control("Sender"), { sender: "sender-absent" }, facets)).toBeUndefined()
})
