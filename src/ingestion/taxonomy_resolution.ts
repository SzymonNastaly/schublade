/**
 * The key that decides whether two sender, category, or tag names denote the same record.
 * It ignores case, diacritics, punctuation, and spacing, so `Mühlbach Bank AG` and
 * `Muhlbach Bank AG.` resolve to one sender.
 */
export function normalizeTaxonomyName(name: string): string {
	return name
		.normalize("NFKD")
		.replace(/\p{M}/gu, "")
		.toLowerCase()
		.replace(/ß/g, "ss")
		.replace(/[^\p{L}\p{N}]+/gu, " ")
		.trim()
}

interface TaxonomyRecord {
	id: string
	normalizedName: string
}

/** Both variants carry the normalized name, which is the key a D1 row is found by. */
export type TaxonomyResolution<TRecord extends TaxonomyRecord> =
	{ kind: "existing"; normalizedName: string; record: TRecord } | { kind: "new"; normalizedName: string; name: string }

export function resolveTaxonomyName<TRecord extends TaxonomyRecord>(
	name: string,
	records: ReadonlyArray<TRecord>,
): TaxonomyResolution<TRecord> {
	const normalizedName = normalizeTaxonomyName(name)
	const record = records.find((candidate) => candidate.normalizedName === normalizedName)
	return record ? { kind: "existing", normalizedName, record } : { kind: "new", normalizedName, name }
}
