import { expect, test } from "vitest"
import { normalizeTaxonomyName, resolveTaxonomyName } from "./taxonomy_resolution"

test("normalizeTaxonomyName ignores case, diacritics, punctuation, and spacing", () => {
	expect(
		["Mühlbach Bank AG", "MUHLBACH  bank AG.", "Zahnarztpraxis Dr. Henrike Vossberg", "Straße", "tax-2026"].map(
			normalizeTaxonomyName,
		),
	).toEqual(["muhlbach bank ag", "muhlbach bank ag", "zahnarztpraxis dr henrike vossberg", "strasse", "tax 2026"])
})

test("resolveTaxonomyName reuses the record with the same normalized name and proposes the rest", () => {
	const records = [{ id: "sender-1", normalizedName: "stadtwerke talbruck gmbh" }]
	expect([
		resolveTaxonomyName("Stadtwerke Talbrück GmbH", records),
		resolveTaxonomyName("Finanzamt Talbrück", records),
	]).toEqual([
		{
			kind: "existing",
			normalizedName: "stadtwerke talbruck gmbh",
			record: { id: "sender-1", normalizedName: "stadtwerke talbruck gmbh" },
		},
		{ kind: "new", normalizedName: "finanzamt talbruck", name: "Finanzamt Talbrück" },
	])
})
