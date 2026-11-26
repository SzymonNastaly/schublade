import { expect, test } from "vitest"
import {
	CLASSIFIED_DOCUMENT_CHARACTERS,
	buildFieldExtractionRequest,
	buildPersonAssignmentRequest,
} from "./classification_request"

const context = {
	markdown: "Rechnung Nr. 4471",
	senderNames: ["Stadtwerke Talbrück GmbH"],
	categoryNames: ["Invoice", "Utility Bill"],
	tagNames: [],
	members: [{ id: "member-1", displayName: "Mira Wiśniewska", addresseeNames: ["Mira Wiśniewska", "M. Wisniewska"] }],
}

test("the field extraction request offers the recorded categories, then the standard categories not yet recorded", () => {
	const { document } = buildFieldExtractionRequest("@cf/cloudflare/clairic-flash", context).fields
	expect(document.properties.category.enum).toEqual([
		"Invoice",
		"Utility Bill",
		"Receipt",
		"Contract",
		"Insurance",
		"Tax Notice",
		"Bank Statement",
		"Medical",
		"Official Identification",
	])
	expect(document.properties.sender.instructions).toMatch(/return it exactly: Stadtwerke Talbrück GmbH$/)
})

test("the person assignment request chooses among the members and the household, and maps the choice to a member", () => {
	const assignment = buildPersonAssignmentRequest("@cf/cloudflare/clef-flash", context)
	expect({
		model: assignment?.request.model,
		choices: Object.keys(assignment?.request.questions.person.criteria ?? {}),
		memberIds: [...(assignment?.memberIds ?? [])],
		withoutMembers: buildPersonAssignmentRequest("@cf/cloudflare/clef-flash", { ...context, members: [] }),
	}).toEqual({
		model: "clef-flash",
		choices: ["Mira Wiśniewska", "household"],
		memberIds: [
			["household", null],
			["Mira Wiśniewska", "member-1"],
		],
		withoutMembers: null,
	})
})

test("both requests place the email that delivered a document before the document text", () => {
	const mailContext = {
		...context,
		mail: {
			senderAddress: "mira@example.com",
			subject: "Fwd: Ihre Stromrechnung Oktober",
			bodyText: "Anbei die Rechnung der Stadtwerke.",
		},
	}
	const expectedState = [
		"Email that delivered the document, sent or forwarded by a household member:",
		"From: mira@example.com",
		"Subject: Fwd: Ihre Stromrechnung Oktober",
		"<email>",
		"Anbei die Rechnung der Stadtwerke.",
		"</email>",
		"",
		"Document text:",
		"<document>",
		"Rechnung Nr. 4471",
		"</document>",
	].join("\n")
	expect([
		buildFieldExtractionRequest("@cf/cloudflare/clairic-flash", mailContext).state,
		buildPersonAssignmentRequest("@cf/cloudflare/clef-flash", mailContext)?.request.state,
	]).toEqual([expectedState, expectedState])
})

test("the models read only the beginning of a long document", () => {
	const markdown = `Rechnung Nr. 4471 ${"x".repeat(100_000)}`
	const { state } = buildFieldExtractionRequest("@cf/cloudflare/clairic-flash", { ...context, markdown })
	expect({ length: state.length, start: state.slice(0, 17) }).toEqual({
		length: CLASSIFIED_DOCUMENT_CHARACTERS,
		start: "Rechnung Nr. 4471",
	})
})
