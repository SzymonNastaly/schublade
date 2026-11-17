const wholeNumbers = new Intl.NumberFormat("en-US")

/** "1 file", "1,240 files". The noun's plural adds an s, which holds for every noun the window counts. */
export function countOf(count: number, noun: string): string {
	return `${wholeNumbers.format(count)} ${count === 1 ? noun : `${noun}s`}`
}

const sizeUnits = ["bytes", "KB", "MB"] as const

/** Decimal units, as Finder shows sizes. */
export function byteSize(bytes: number): string {
	let value = bytes
	let unit = 0
	while (value >= 1000 && unit < sizeUnits.length - 1) {
		value /= 1000
		unit += 1
	}
	return unit === 0 ? `${bytes} bytes` : `${value.toFixed(1)} ${sizeUnits[unit]}`
}
