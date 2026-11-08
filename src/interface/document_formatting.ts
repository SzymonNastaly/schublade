// The interface is English, and one fixed locale keeps server and browser rendering identical.
const documentDateFormat = new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeZone: "UTC" })
const timestampFormat = new Intl.DateTimeFormat("en-GB", {
	day: "numeric",
	month: "short",
	year: "numeric",
	hour: "2-digit",
	minute: "2-digit",
	timeZone: "UTC",
	timeZoneName: "short",
})
const amountFormat = new Intl.NumberFormat("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 })

/** An ISO 8601 calendar date such as 2026-10-05 as 5 Oct 2026, or unchanged when it is not a date. */
export function formatDocumentDate(isoDate: string): string {
	const date = new Date(`${isoDate}T00:00:00Z`)
	return Number.isNaN(date.getTime()) ? isoDate : documentDateFormat.format(date)
}

/** A moment such as 8 Nov 2026, 12:56 UTC. The server knows no viewer's time zone, so both sides name UTC. */
export function formatTimestamp(moment: Date): string {
	return timestampFormat.format(moment)
}

export function formatAmount(amount: number, currency: string | undefined): string {
	return currency === undefined ? amountFormat.format(amount) : `${amountFormat.format(amount)} ${currency}`
}

const periodUnits = { Y: "year", M: "month", W: "week", D: "day" } as const

/** An ISO 8601 period such as P3M as 3 months, or unchanged when it has any other form. */
export function formatPeriod(period: string): string {
	const match = /^P(?<count>\d+)(?<unit>[YMWD])$/.exec(period)
	if (match?.groups === undefined) return period
	const { count, unit } = match.groups as { count: string; unit: keyof typeof periodUnits }
	return `${count} ${periodUnits[unit]}${count === "1" ? "" : "s"}`
}

/** An IBAN in groups of four characters, as it is printed on paper. */
export function formatIban(iban: string): string {
	return iban.replace(/\s+/g, "").replace(/(.{4})(?=.)/g, "$1 ")
}
