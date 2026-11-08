import { expect, test } from "vitest"
import { documentDetailRows, offeredFieldKeys } from "./document_detail_presentation"
import type { ArchiveFacets, ListedDocument } from "../archive/document_listing"

const facets: ArchiveFacets = {
	members: [{ id: "member-1", name: "Maja" }],
	senders: [{ id: "sender-1", name: "Nordkabel" }],
	categories: [{ id: "category-1", name: "Rechnung", expectedFields: ["amount", "due_date"] }],
	tags: [{ id: "tag-1", name: "tax-2026" }],
}

const archivedDocument: ListedDocument = {
	id: "document-1",
	status: "archived",
	title: "Nordkabel invoice",
	documentDate: "2026-10-05",
	senderName: "Nordkabel",
	categoryName: "Rechnung",
	personMemberId: null,
	personName: null,
	summary: null,
	mimeType: "application/pdf",
	pageCount: 1,
	verificationReason: null,
	tagNames: ["tax-2026", "unlisted"],
	fields: [
		{ fieldKey: "currency", value: "EUR", confidence: 0.9 },
		{ fieldKey: "amount", value: 1235, confidence: 0.9 },
		{ fieldKey: "due_date", value: "2026-11-01", confidence: 0.9 },
		{ fieldKey: "iban", value: null, confidence: null },
	],
}

const noFields = {
	amount: "",
	currency: "",
	due_date: "",
	iban: "",
	invoice_number: "",
	policy_number: "",
	renewal_date: "",
	cancellation_period: "",
}

test("reading shows filled-in values in order, linking those the facets hold", () => {
	expect(documentDetailRows(archivedDocument, facets)).toEqual([
		{ label: "Date", values: [{ text: "5 Oct 2026" }] },
		{ label: "Sender", values: [{ text: "Nordkabel", filter: { sender: "sender-1" } }] },
		{ label: "Category", values: [{ text: "Rechnung", filter: { category: "category-1" } }] },
		{ label: "Person", values: [{ text: "Household", filter: { person: "household" } }] },
		{ label: "Tags", values: [{ text: "tax-2026", filter: { tag: "tag-1" } }, { text: "unlisted" }] },
		{ label: "Amount", values: [{ text: "1,235.00 EUR" }] },
		{ label: "Due date", values: [{ text: "1 Nov 2026" }] },
	])
})

test("a document still in processing has no person and no rows", () => {
	const unfinished: ListedDocument = {
		...archivedDocument,
		status: "classifying",
		documentDate: null,
		senderName: null,
		categoryName: null,
		tagNames: [],
		fields: [],
	}
	expect(documentDetailRows(unfinished, facets)).toEqual([])
})

test("a household member links to the archive filtered by that member", () => {
	const assigned = { ...archivedDocument, personMemberId: "member-1", personName: "Maja" }
	expect(documentDetailRows(assigned, facets).find((row) => row.label === "Person")).toEqual({
		label: "Person",
		values: [{ text: "Maja", filter: { person: "member-1" } }],
	})
})

test("the form offers the fields the category expects and those that hold a value", () => {
	const fields = { ...noFields, iban: "DE02120300000000202051" }
	expect(offeredFieldKeys("rechnung", facets.categories, [fields])).toEqual(["amount", "due_date", "iban"])
})

test("a standard category without a record offers its standard fields", () => {
	expect(offeredFieldKeys("Contract", facets.categories, [noFields])).toEqual([
		"policy_number",
		"renewal_date",
		"cancellation_period",
	])
})

test("a field keeps its input while its value is cleared", () => {
	const atStart = { ...noFields, iban: "DE02120300000000202051" }
	expect(offeredFieldKeys("Unknown name", facets.categories, [atStart, noFields])).toEqual(["iban"])
})
