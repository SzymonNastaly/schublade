import { expect, test } from "vitest"
import { buildClassificationRequest } from "./classification_prompt"

test("buildClassificationRequest lists the members, the taxonomy, and the standard categories not yet recorded", () => {
	const request = buildClassificationRequest({
		markdown: "Rechnung Nr. 4471",
		senderNames: ["Stadtwerke Talbrück GmbH"],
		categoryNames: ["Invoice", "Utility Bill"],
		tagNames: [],
		members: [{ id: "member-1", displayName: "Mira Wiśniewska", addresseeNames: ["Mira Wiśniewska", "M. Wisniewska"] }],
	})
	expect(request.prompt).toBe(
		[
			"Household members:",
			"- member-1: Mira Wiśniewska, printed as Mira Wiśniewska or M. Wisniewska",
			"",
			"Senders: Stadtwerke Talbrück GmbH",
			"Categories: Invoice; Utility Bill; Receipt; Contract; Insurance; Tax Notice; Bank Statement; Medical; Official Identification",
			"Tags: none",
			"",
			"Document text:",
			"<document>",
			"Rechnung Nr. 4471",
			"</document>",
		].join("\n"),
	)
	expect(request.system).toContain('"enum":["household","member-1"]')
})

test("buildClassificationRequest places the email that delivered a document before the document text", () => {
	const request = buildClassificationRequest({
		markdown: "Rechnung Nr. 4471",
		mail: {
			senderAddress: "mira@example.com",
			subject: "Fwd: Ihre Stromrechnung Oktober",
			bodyText: "Anbei die Rechnung der Stadtwerke.",
		},
		senderNames: [],
		categoryNames: [],
		tagNames: [],
		members: [],
	})
	expect(request.prompt.split("\n").slice(7)).toEqual([
		"Email that delivered the document:",
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
	])
})
