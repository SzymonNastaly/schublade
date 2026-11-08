import { expect, test } from "vitest"
import { renderConsentPage } from "./consent_page"
import { describeAuthorizationScope, grantedAuthorizationScope } from "./grant_selection"
import type { ConsentDescription } from "@cloudflare/workers-oauth-provider"

const formOf = (...entries: Array<[string, string]>) => {
	const form = new FormData()
	for (const [name, value] of entries) form.append(name, value)
	return form
}

test("grantedAuthorizationScope reads the consent form and refuses a form that selects nothing usable", () => {
	expect(grantedAuthorizationScope(formOf(["access", "everything"], ["allowedTags", "ignored"]))).toEqual({
		level: "read",
	})
	expect(
		grantedAuthorizationScope(
			formOf(
				["access", "selected"],
				["allowedCategories", "invoice"],
				["allowedCategories", "invoice"],
				["deniedTags", "private"],
			),
		),
	).toEqual({ level: "read", allowedCategories: ["invoice"], deniedTags: ["private"] })
	expect(grantedAuthorizationScope(formOf(["access", "selected"]))).toBeUndefined()
	expect(grantedAuthorizationScope(formOf(["allowedCategories", "invoice"]))).toBeUndefined()
})

const facets = {
	members: [],
	householdDocumentCount: 0,
	senders: [{ id: "werkhof", name: "Werkhof", documentCount: 1 }],
	categories: [{ id: "invoice", name: "<Invoice>", documentCount: 2, expectedFields: [] }],
	tags: [{ id: "private", name: "private", documentCount: 3 }],
}

test("describeAuthorizationScope names what a grant admits", () => {
	expect(describeAuthorizationScope({ level: "read" }, facets)).toBe("All documents")
	expect(
		describeAuthorizationScope({ level: "read", allowedSenders: ["werkhof"], deniedTags: ["private", "gone"] }, facets),
	).toBe("Senders: Werkhof. Excluding tags: private, Unknown")
})

const consent: ConsentDescription = {
	clientId: "client",
	clientName: '<script>alert("name")</script>',
	redirectUri: "http://127.0.0.1:9000/callback",
	redirectHost: "127.0.0.1",
	redirectIsLoopback: true,
	scope: [],
}

test("the consent page escapes the name a client chose and warns about a local program", () => {
	const page = renderConsentPage({ consent, handle: "handle-value", facets })

	expect(page).not.toContain("<script>alert")
	expect(page).toContain("&lt;script&gt;alert")
	expect(page).toContain("&lt;Invoice&gt; (2)")
	expect(page).toContain("Access goes to a program on this computer")
	expect(page).toContain('value="handle-value"')
})
