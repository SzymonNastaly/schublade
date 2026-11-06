import { z } from "zod"
import { buildClassificationSchema, standardCategories } from "./document_classification"
import { normalizeTaxonomyName } from "./taxonomy_resolution"

export interface ClassificationContext {
	markdown: string
	senderNames: ReadonlyArray<string>
	categoryNames: ReadonlyArray<string>
	tagNames: ReadonlyArray<string>
	members: ReadonlyArray<{ id: string; displayName: string; addresseeNames: ReadonlyArray<string> }>
}

const SYSTEM_PROMPT = `You file documents into the archive of one household in Germany. Read the document text and return the requested JSON object.

- Sender: the organization, authority, or person that issued the document, named as in its address line, imprint, or signature. Leave out a logo monogram that precedes the name, and add no legal form the document does not print. When a listed sender denotes the same organization, return the listed name exactly.
- Category: return one listed category exactly as written, chosen by subject before form: a bill from a doctor or dentist is Medical, an assessment from a tax office is Tax Notice, and a policy from an insurer is Insurance. Name a new category only when none fits.
- Tags: prefer listed tags. Return no tag rather than a vague one.
- Person: the household member the document concerns, such as the addressee of a personal letter, the patient of a medical document, the account holder of a bank statement, or the taxpayer of a tax notice. Return household when the document concerns several members or no particular member, even when it is addressed to one of them, such as a joint contract, a policy that also insures other members, or a shop receipt.
- Title: English, in the form "<sender without legal form> <document type> <period or subject>", such as "Vodafone Kabel Deutschland Invoice October 2026".
- Fields: fill every field the document prints, whatever its category, and return null for the others. Copy numbers and identifiers exactly, digit by digit. Do not compute or guess a value.
- The character U+FFFD (\uFFFD) marks a character the text recognizer could not read. It most often stands for a currency symbol such as €.

Return one JSON object that matches this JSON Schema:`

function listOrNone(names: ReadonlyArray<string>): string {
	return names.length === 0 ? "none" : names.join("; ")
}

/** Existing names first, then each standard name that no existing name already denotes. */
function mergeCategoryNames(existingNames: ReadonlyArray<string>): Array<string> {
	const existingKeys = new Set(existingNames.map(normalizeTaxonomyName))
	const standardNames = standardCategories
		.map((category) => category.name)
		.filter((name) => !existingKeys.has(normalizeTaxonomyName(name)))
	return [...existingNames, ...standardNames]
}

/**
 * Without the schema in the prompt, Gemma 4 returned every extracted field as null although
 * the response format constrained its output, so the system prompt carries the schema.
 */
export function buildClassificationRequest(context: ClassificationContext) {
	const schema = buildClassificationSchema(context.members.map((member) => member.id))
	const memberLines = context.members.map(
		(member) => `- ${member.id}: ${member.displayName}, printed as ${member.addresseeNames.join(" or ")}`,
	)
	const prompt = [
		"Household members:",
		...(memberLines.length === 0 ? ["none"] : memberLines),
		"",
		`Senders: ${listOrNone(context.senderNames)}`,
		`Categories: ${listOrNone(mergeCategoryNames(context.categoryNames))}`,
		`Tags: ${listOrNone(context.tagNames)}`,
		"",
		"Document text:",
		"<document>",
		context.markdown,
		"</document>",
	].join("\n")
	return { schema, system: `${SYSTEM_PROMPT}\n${JSON.stringify(z.toJSONSchema(schema))}`, prompt }
}
