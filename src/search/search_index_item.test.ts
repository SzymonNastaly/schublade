import { expect, test } from "vitest"
import {
	composeSearchIndexContent,
	documentIdOfItemName,
	searchIndexItemName,
	searchIndexMetadata,
} from "./search_index_item"
import type { IndexedDocument } from "./search_index_item"

const dentalInvoice: IndexedDocument = {
	id: "7d0e4f52-9a1b-4c3d-8e2f-1a2b3c4d5e6f",
	title: "Zahnarztpraxis Vossberg Invoice August 2026",
	documentDate: "2026-08-27",
	senderId: "0b6c1f7e-3d2a-4e5b-9c8d-7f6e5d4c3b2a",
	senderName: "Zahnarztpraxis Dr. Henrike Vossberg",
	categoryId: "5e4d3c2b-1a09-4f8e-b7d6-c5b4a3928170",
	personMemberId: "1a2b3c4d-5e6f-8a1b-9c2d-3e4f5a6b7c8d",
	summary: "This is a dental invoice for Lena Becker. It requests 91.84 EUR by 26 September 2026.",
	tagNames: ["dental", "reimbursable"],
	markdown: "Rechnung Nr. ZA-2026-0193\n\nIBAN DE80 9701 1320 0605 1900 31\n",
}

test("searchIndexMetadata names the member, sender, and category, and dates the document at midnight UTC", () => {
	expect(searchIndexMetadata(dentalInvoice)).toEqual({
		person: "1a2b3c4d-5e6f-8a1b-9c2d-3e4f5a6b7c8d",
		sender: "0b6c1f7e-3d2a-4e5b-9c8d-7f6e5d4c3b2a",
		category: "5e4d3c2b-1a09-4f8e-b7d6-c5b4a3928170",
		document_date: "2026-08-27T00:00:00Z",
	})
	expect(
		searchIndexMetadata({
			...dentalInvoice,
			personMemberId: null,
			senderId: null,
			categoryId: null,
			documentDate: null,
		}),
	).toEqual({ person: "household" })
})

test("composeSearchIndexContent places the title, sender, tags, and summary before the Markdown", () => {
	expect(composeSearchIndexContent(dentalInvoice)).toBe(
		[
			"# Zahnarztpraxis Vossberg Invoice August 2026",
			"Sender: Zahnarztpraxis Dr. Henrike Vossberg",
			"Tags: dental, reimbursable",
			"",
			"This is a dental invoice for Lena Becker. It requests 91.84 EUR by 26 September 2026.",
			"",
			"Rechnung Nr. ZA-2026-0193",
			"",
			"IBAN DE80 9701 1320 0605 1900 31",
			"",
		].join("\n"),
	)
})

test("documentIdOfItemName reads the identifier of an item name and ignores other items", () => {
	expect([
		documentIdOfItemName(searchIndexItemName(dentalInvoice.id)),
		documentIdOfItemName("handbook.md"),
		documentIdOfItemName(`${dentalInvoice.id}.pdf`),
	]).toEqual(["7d0e4f52-9a1b-4c3d-8e2f-1a2b3c4d5e6f", undefined, undefined])
})
