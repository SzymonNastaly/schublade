import { expect, test } from "vitest"
import {
	composeSearchString,
	parseSearchString,
	rankPassages,
	searchCriteriaSchema,
	searchIndexFilter,
} from "./search_criteria"

const memberId = "1a2b3c4d-5e6f-8a1b-9c2d-3e4f5a6b7c8d"
const senderId = "0b6c1f7e-3d2a-4e5b-9c8d-7f6e5d4c3b2a"
const categoryId = "5e4d3c2b-1a09-4f8e-b7d6-c5b4a3928170"
const tagId = "9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a"

test("searchCriteriaSchema parses URL parameters and rejects an impossible date", () => {
	expect(searchCriteriaSchema.parse({ query: " electricity bill ", person: "household", minimumAmount: "50" })).toEqual(
		{ query: "electricity bill", person: "household", minimumAmount: 50 },
	)
	expect(searchCriteriaSchema.safeParse({ earliestDocumentDate: "2026-02-30" }).success).toBe(false)
})

test("parseSearchString keeps a numeric query as typed", () => {
	expect([parseSearchString("?query=1.50"), parseSearchString("?query=1e3")]).toEqual([
		{ query: "1.50" },
		{ query: "1e3" },
	])
})

test("parseSearchString drops an unreadable or unknown parameter and keeps the others", () => {
	expect(parseSearchString("?query=Nordkabel&minimumAmount=abc&utm_source=x")).toEqual({
		query: "Nordkabel",
	})
})

test("parseSearchString keeps the entry that the Pending verification review opens", () => {
	expect(parseSearchString(`?entry=sender-${senderId}&utm_source=x`)).toEqual({ entry: `sender-${senderId}` })
})

test("composeSearchString writes criteria that parseSearchString reads back unchanged", () => {
	const searchString = composeSearchString({ query: "1.50", minimumAmount: 50, sender: undefined })
	expect({ searchString, criteria: parseSearchString(searchString) }).toEqual({
		searchString: "?query=1.50&minimumAmount=50",
		criteria: { query: "1.50", minimumAmount: 50 },
	})
})

test("searchIndexFilter sends person, sender, category, and date range to AI Search and leaves tags and amounts to D1", () => {
	expect(
		searchIndexFilter({
			person: memberId,
			sender: senderId,
			category: categoryId,
			tag: tagId,
			earliestDocumentDate: "2026-09-01",
			latestDocumentDate: "2026-09-30",
			minimumAmount: 50,
			maximumAmount: 100,
		}),
	).toEqual({
		person: memberId,
		sender: senderId,
		category: categoryId,
		document_date: { $gte: "2026-09-01T00:00:00Z", $lte: "2026-09-30T00:00:00Z" },
	})
	expect(searchIndexFilter({ tag: tagId, minimumAmount: 50 })).toBeUndefined()
})

test("rankPassages keeps the best chunk of each document and excerpts it around the query", () => {
	const chunk = (key: string, score: number, text: string) => ({ id: key, type: "text", score, text, item: { key } })
	const dentalInvoiceId = "7d0e4f52-9a1b-4c3d-8e2f-1a2b3c4d5e6f"
	const rentalContractId = "2c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f"
	const preamble =
		"Sehr geehrte Frau Becker, für die Behandlung im August berechnen wir die folgenden Leistungen. ".repeat(3)
	expect(
		rankPassages(
			[
				chunk(`${rentalContractId}.md`, 0.41, "# Mietvertrag\n\nDie Kaution beträgt drei Monatsmieten."),
				chunk(`${dentalInvoiceId}.md`, 0.52, "# Zahnarzt\n\nRechnung"),
				chunk("handbook.md", 0.9, "Unrelated item"),
				chunk(
					`${dentalInvoiceId}.md`,
					0.88,
					`${preamble}Bitte überweisen Sie den Betrag auf das Konto IBAN DE80 9701 1320 0605 1900 31 bis zum 26.09.2026.`,
				),
			],
			"DE80 9701 1320 0605 1900 31",
		),
	).toEqual([
		{
			documentId: dentalInvoiceId,
			passage:
				"…wir die folgenden Leistungen. Bitte überweisen Sie den Betrag auf das Konto IBAN DE80 9701 1320 0605 1900 31 bis zum 26.09.2026.",
		},
		{ documentId: rentalContractId, passage: "Mietvertrag Die Kaution beträgt drei Monatsmieten." },
	])
})
