import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair } from "jose"
import { describe, expect, test } from "vitest"
import { requireAccess } from "./access_verification"

const TEAM_DOMAIN = "archive-test.cloudflareaccess.com"
const AUDIENCE = "4714c1358e65fe4b408ad6d432a5f878f08194bdb4752441fd56faefa9b2b6f2"
const environment = { ACCESS_TEAM_DOMAIN: TEAM_DOMAIN, ACCESS_AUD: AUDIENCE }

const { privateKey, publicKey } = await generateKeyPair("RS256")
const keySet = createLocalJWKSet({ keys: [{ ...(await exportJWK(publicKey)), kid: "test-key", alg: "RS256" }] })
const serveArchive = requireAccess(
	() => new Response("archive page"),
	() => keySet,
)

function signAssertion(claims: { audience: string; expiresAt: string | number }) {
	return new SignJWT({ email: "member@example.com" })
		.setProtectedHeader({ alg: "RS256", kid: "test-key" })
		.setIssuer(`https://${TEAM_DOMAIN}`)
		.setAudience(claims.audience)
		.setIssuedAt()
		.setExpirationTime(claims.expiresAt)
		.sign(privateKey)
}

function requestWith(assertion?: string) {
	const headers = assertion ? { "Cf-Access-Jwt-Assertion": assertion } : undefined
	return new Request("https://schublade.example/", { headers })
}

async function outcome(response: Response) {
	return { status: response.status, body: await response.text() }
}

describe("requireAccess", () => {
	test("serves the request when the assertion is valid", async () => {
		const assertion = await signAssertion({ audience: AUDIENCE, expiresAt: "5 minutes" })
		expect(await outcome(await serveArchive(requestWith(assertion), environment))).toEqual({
			status: 200,
			body: "archive page",
		})
	})

	test("rejects an assertion issued for another application", async () => {
		const assertion = await signAssertion({ audience: "another-application", expiresAt: "5 minutes" })
		expect(await outcome(await serveArchive(requestWith(assertion), environment))).toEqual({
			status: 403,
			body: "Access denied: audience_mismatch",
		})
	})

	test("rejects an expired assertion", async () => {
		const assertion = await signAssertion({ audience: AUDIENCE, expiresAt: Math.floor(Date.now() / 1000) - 60 })
		expect(await outcome(await serveArchive(requestWith(assertion), environment))).toEqual({
			status: 403,
			body: "Access denied: assertion_expired",
		})
	})

	test("rejects a request without an assertion", async () => {
		expect(await outcome(await serveArchive(requestWith(), environment))).toEqual({
			status: 403,
			body: "Access denied: assertion_missing",
		})
	})

	test.each([
		["ACCESS_TEAM_DOMAIN", { ...environment, ACCESS_TEAM_DOMAIN: "" }],
		["ACCESS_AUD", { ...environment, ACCESS_AUD: "" }],
	])("rejects a valid assertion when %s is empty", async (_variable, blankEnvironment) => {
		const assertion = await signAssertion({ audience: AUDIENCE, expiresAt: "5 minutes" })
		expect(await outcome(await serveArchive(requestWith(assertion), blankEnvironment))).toEqual({
			status: 403,
			body: "Access denied: access_unconfigured",
		})
	})
})
