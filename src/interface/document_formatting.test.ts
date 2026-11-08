import { expect, test } from "vitest"
import { formatAmount, formatDocumentDate, formatIban, formatPeriod, formatTimestamp } from "./document_formatting"

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

test("an ISO 8601 period reads as words", () => {
	expect(formatPeriod("P3M")).toBe("3 months")
	expect(formatPeriod("P1Y")).toBe("1 year")
	expect(formatPeriod("three months")).toBe("three months")
})

test("an IBAN is grouped in fours", () => {
	expect(formatIban("DE65960512400220417090")).toBe("DE65 9605 1240 0220 4170 90")
})

test("formatTimestamp names one time zone, so the server and the browser render the same text", () => {
	expect(formatTimestamp(new Date("2026-11-08T12:56:30Z"))).toBe("8 Nov 2026, 12:56 UTC")
})
