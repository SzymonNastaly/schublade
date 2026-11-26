import { z } from "zod"
import { standardCategories } from "./document_classification"
import { normalizeTaxonomyName } from "./taxonomy_resolution"

/** The email that delivered a document, as context for its classification. */
export const mailContextSchema = z.strictObject({
	senderAddress: z.string(),
	subject: z.string(),
	bodyText: z.string(),
})

export type MailContext = z.infer<typeof mailContextSchema>

export interface ClassificationContext {
	markdown: string
	mail?: MailContext
	senderNames: ReadonlyArray<string>
	categoryNames: ReadonlyArray<string>
	tagNames: ReadonlyArray<string>
	members: ReadonlyArray<{ id: string; displayName: string; addresseeNames: ReadonlyArray<string> }>
}

const currencyCodes = ["EUR", "USD", "GBP", "CHF", "PLN", "CZK", "DKK", "SEK", "NOK"]

/**
 * Clairic reads the whole state once per generated field, and once more for all typed fields
 * together, so every generated value sits in one object: two reads per document. Without
 * `nullable: false`, the object came back null for a document without money fields.
 */
export function buildFieldExtractionRequest(modelName: string, context: ClassificationContext) {
	// Naming the legal form and the capitalization turned FRISCHEMARKT TALBRÜCK, the receipt's
	// header, into Frischemarkt Talbrück GmbH, its footer. Logo monograms such as NK remain.
	const sender =
		"Legal name of the organization, authority, or person that issued the document, as printed in its imprint, footer, bank details, or signature, with its legal form such as GmbH or AG when printed there, in normal capitalization, without a logo abbreviation such as NK that precedes the name"
	const tags = "Zero to three lowercase cross-cutting labels separated by commas, such as tax-2026"
	return {
		model: modelSelector(modelName),
		state: composeClassificationState(context),
		fields: {
			document: {
				type: "object",
				nullable: false,
				properties: {
					sender: {
						type: "text",
						knowledge: true,
						instructions: withKnownNames(
							sender,
							"When one of these denotes the same issuer, return it exactly",
							context.senderNames,
						),
					},
					title: {
						type: "text",
						knowledge: true,
						instructions:
							"English title in the form <sender without legal form> <document type> <period or subject>, such as Vodafone Kabel Deutschland Invoice October 2026",
					},
					category: {
						type: "enum",
						enum: mergeCategoryNames(context.categoryNames),
						instructions:
							"Chosen by subject before form: a bill from a doctor or dentist is Medical, an assessment from a tax office is Tax Notice, a policy from an insurer is Insurance",
					},
					amount: { type: "number", instructions: "Final total to pay, paid, or refunded" },
					currency: {
						type: "enum",
						enum: currencyCodes,
						instructions: "Currency of the amount. The character � marks an unreadable character, most often €",
					},
					iban: { type: "text" },
					invoice_number: { type: "text", instructions: "Invoice, receipt, or transaction number" },
					policy_number: { type: "text", instructions: "Contract or insurance policy number" },
					tags: {
						type: "text",
						knowledge: true,
						instructions: withKnownNames(tags, "Prefer these", context.tagNames),
					},
				},
			},
			// Typed fields without source_only: with it, Clairic refused 05.10.2026 as an invalid printed date.
			document_date: { type: "date", instructions: "Date the document was issued" },
			due_date: { type: "date", instructions: "Date by which the amount must be paid" },
			renewal_date: { type: "date", instructions: "Date the contract or policy next renews or ends" },
			cancellation_period: {
				type: "duration",
				unit: "months",
				integer: true,
				instructions: "Notice period (Kündigungsfrist)",
			},
		},
	}
}

const HOUSEHOLD_CHOICE = "household"

/**
 * A Clef question that chooses the member a document concerns. Each choice is a member's
 * display name, so `memberIds` maps the answer back to a member, and `household` to null.
 * Without members, every document concerns the household and no request is needed.
 */
export function buildPersonAssignmentRequest(modelName: string, context: ClassificationContext) {
	if (context.members.length === 0) return null
	const memberIds = new Map<string, string | null>([[HOUSEHOLD_CHOICE, null]])
	const criteria: Record<string, string> = {}
	for (const member of context.members) {
		let choice = member.displayName
		for (let ordinal = 2; memberIds.has(choice); ordinal++) choice = `${member.displayName} ${ordinal}`
		memberIds.set(choice, member.id)
		criteria[choice] =
			`${member.displayName}, printed as ${member.addresseeNames.join(" or ")}, alone: the addressee of a personal letter, the patient, the account holder, or the taxpayer`
	}
	criteria[HOUSEHOLD_CHOICE] =
		"Several members or no particular member, even when addressed to one, such as a joint contract, a policy that insures others, or a shop receipt"
	return {
		memberIds,
		request: {
			model: modelSelector(modelName),
			state: composeClassificationState(context),
			questions: { person: { type: "choice", instructions: "Whom does the document concern?", criteria } },
		},
	}
}

/** Both models take the short model name, such as clairic-flash, in the body. */
function modelSelector(modelName: string): string {
	return modelName.slice(modelName.lastIndexOf("/") + 1)
}

function withKnownNames(instructions: string, introduction: string, names: ReadonlyArray<string>): string {
	return names.length === 0 ? instructions : `${instructions}. ${introduction}: ${names.join("; ")}`
}

/** Existing names first, then each standard name that no existing name already denotes. */
function mergeCategoryNames(existingNames: ReadonlyArray<string>): Array<string> {
	const existingKeys = new Set(existingNames.map(normalizeTaxonomyName))
	const standardNames = standardCategories
		.map((category) => category.name)
		.filter((name) => !existingKeys.has(normalizeTaxonomyName(name)))
	return [...existingNames, ...standardNames]
}

/** The document text, preceded by the email that delivered it, if any. */
/**
 * Clairic rejects a request above about 65,000 input tokens and bills the whole text once per read,
 * so the models read the beginning of a long document, where its sender, date, and amounts stand.
 * 24,000 characters hold about eight pages of German paperwork.
 */
export const CLASSIFIED_DOCUMENT_CHARACTERS = 24_000
const CLASSIFIED_MAIL_CHARACTERS = 4_000

function composeClassificationState(context: ClassificationContext): string {
	const documentText = context.markdown.slice(0, CLASSIFIED_DOCUMENT_CHARACTERS)
	if (context.mail === undefined) return documentText
	return [
		"Email that delivered the document, sent or forwarded by a household member:",
		`From: ${context.mail.senderAddress}`,
		`Subject: ${context.mail.subject}`,
		"<email>",
		context.mail.bodyText.slice(0, CLASSIFIED_MAIL_CHARACTERS),
		"</email>",
		"",
		"Document text:",
		"<document>",
		documentText,
		"</document>",
	].join("\n")
}
