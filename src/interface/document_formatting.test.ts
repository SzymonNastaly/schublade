import { expect, test } from "vitest"
import { formatAmount, formatDocumentDate } from "./document_formatting"

test("a calendar date keeps its day in every time zone", () => {
	expect(formatDocumentDate("2026-10-05")).toBe("5 Oct 2026")
})

test("text that is not a date stays readable", () => {
	expect(formatDocumentDate("unreadable")).toBe("unreadable")
})

test("an amount has thousands separators, two decimals, and its currency", () => {
	expect(formatAmount(1235, "EUR")).toBe("1,235.00 EUR")
	expect(formatAmount(42.8, undefined)).toBe("42.80")
})
