// The interface is English, and one fixed locale keeps server and browser rendering identical.
const documentDateFormat = new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeZone: "UTC" })
const amountFormat = new Intl.NumberFormat("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 })

/** An ISO 8601 calendar date such as 2026-10-05 as 5 Oct 2026, or unchanged when it is not a date. */
export function formatDocumentDate(isoDate: string): string {
	const date = new Date(`${isoDate}T00:00:00Z`)
	return Number.isNaN(date.getTime()) ? isoDate : documentDateFormat.format(date)
}

export function formatAmount(amount: number, currency: string | undefined): string {
	return currency === undefined ? amountFormat.format(amount) : `${amountFormat.format(amount)} ${currency}`
}
