import { createRemoteJWKSet, errors, jwtVerify } from "jose"
import type { JWTVerifyGetKey } from "jose"
import type { Caller } from "../authorization/caller_authorization"

interface AccessEnvironment {
	ACCESS_TEAM_DOMAIN: string
	ACCESS_AUD: string
}

type AccessDenialReason =
	| "access_unconfigured"
	| "assertion_missing"
	| "assertion_expired"
	| "audience_mismatch"
	| "issuer_mismatch"
	| "assertion_invalid"

type KeySetResolver = (issuer: string) => JWTVerifyGetKey

type MemberSessionHandler = (
	request: Request,
	caller: Extract<Caller, { kind: "member_session" }>,
) => Response | Promise<Response>

const ASSERTION_HEADER = "Cf-Access-Jwt-Assertion"

// A key set fetches and caches the signing keys of one Access team for the life of the isolate.
const remoteKeySets = new Map<string, JWTVerifyGetKey>()

function resolveRemoteKeySet(issuer: string): JWTVerifyGetKey {
	let keySet = remoteKeySets.get(issuer)
	if (!keySet) {
		keySet = createRemoteJWKSet(new URL("/cdn-cgi/access/certs", issuer))
		remoteKeySets.set(issuer, keySet)
	}
	return keySet
}

function denialReasonOf(error: unknown): AccessDenialReason {
	if (error instanceof errors.JWTExpired) return "assertion_expired"
	if (error instanceof errors.JWTClaimValidationFailed && error.claim === "aud") return "audience_mismatch"
	if (error instanceof errors.JWTClaimValidationFailed && error.claim === "iss") return "issuer_mismatch"
	if (error instanceof errors.JOSEError) return "assertion_invalid"
	throw error
}

async function findDenialReason(
	request: Request,
	environment: AccessEnvironment,
	resolveKeySet: KeySetResolver,
): Promise<AccessDenialReason | undefined> {
	const teamDomain = environment.ACCESS_TEAM_DOMAIN.trim()
	const audience = environment.ACCESS_AUD.trim()
	if (!teamDomain || !audience) return "access_unconfigured"
	const assertion = request.headers.get(ASSERTION_HEADER)
	if (!assertion) return "assertion_missing"
	const issuer = `https://${teamDomain}`
	try {
		await jwtVerify(assertion, resolveKeySet(issuer), { issuer, audience, algorithms: ["RS256"] })
		return undefined
	} catch (error) {
		return denialReasonOf(error)
	}
}

// Every browser request needs a Cloudflare Access assertion for the configured application.
// Blank Access variables deny every request instead of admitting it.
export function requireAccess(handler: MemberSessionHandler, resolveKeySet: KeySetResolver = resolveRemoteKeySet) {
	return async (request: Request, environment: AccessEnvironment): Promise<Response> => {
		const denialReason = await findDenialReason(request, environment, resolveKeySet)
		if (denialReason) return new Response(`Access denied: ${denialReason}`, { status: 403 })
		return handler(request, { kind: "member_session" })
	}
}
