const clock = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" })
const dayAndClock = new Intl.DateTimeFormat(undefined, {
	day: "numeric",
	month: "short",
	hour: "numeric",
	minute: "2-digit",
})

/** The time of day in the person's own format, for moments within the next or last hours. */
export function clockTime(timestamp: number): string {
	return clock.format(timestamp)
}

/** "Today, 14:02" or "12 Nov, 09:15", in the person's own format. */
export function receiptTime(timestamp: number): string {
	const received = new Date(timestamp)
	return received.toDateString() === new Date().toDateString()
		? `Today, ${clock.format(received)}`
		: dayAndClock.format(received)
}
