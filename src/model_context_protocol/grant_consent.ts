import { AuthorizationError, getOAuthApi } from "@cloudflare/workers-oauth-provider"
import { queryArchiveFacets } from "../archive/document_listing"
import { permits } from "../authorization/caller_authorization"
import { connectDatabase } from "../database/client"
import { recordAuthorizationGrant } from "./authorization_grants"
import { GRANTED_OAUTH_SCOPES, HOUSEHOLD_GRANT_SUBJECT, authorizationServerOptions } from "./authorization_server"
import { renderConsentPage } from "./consent_page"
import { grantedAuthorizationScope } from "./grant_selection"
import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider"
import type { Caller } from "../authorization/caller_authorization"
import type { ModelContextEnvironment } from "./authorization_server"

const plainText = (text: string, status: number) =>
	new Response(text, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } })

async function showConsent(environment: ModelContextEnvironment, oauth: OAuthHelpers, request: Request) {
	const authorizationRequest = await oauth.parseAuthRequest(request)
	const consent = await oauth.describeConsent(authorizationRequest)
	const facets = await queryArchiveFacets(connectDatabase(environment.DATABASE))
	const { handle, headers } = await oauth.beginConsent(authorizationRequest)
	headers.set("Content-Type", "text/html; charset=utf-8")
	return new Response(renderConsentPage({ consent, handle, facets }), { headers })
}

async function decideConsent(environment: ModelContextEnvironment, oauth: OAuthHelpers, request: Request) {
	const form = await request.formData()
	const handle = String(form.get("handle"))
	if (form.get("decision") !== "approve") {
		const { headers } = await oauth.denyConsent(request, handle)
		return new Response(null, { status: 302, headers })
	}
	const authorizationScope = grantedAuthorizationScope(form)
	// The handle works once and is not yet consumed, so the browser's Back button returns to a working form.
	if (authorizationScope === undefined) {
		return plainText("Go back and select at least one entry, or allow every archived document.", 400)
	}
	const approved = await oauth.approveConsent(request, handle, { scope: GRANTED_OAUTH_SCOPES })
	const { clientId, clientName } = await oauth.describeConsent(approved.request)
	const grantId = crypto.randomUUID()
	const { redirectTo } = await oauth.completeAuthorization({
		request: approved.request,
		userId: HOUSEHOLD_GRANT_SUBJECT,
		metadata: {},
		scope: approved.request.scope,
		props: { authorizationGrantId: grantId },
	})
	// Recorded last: a token without this row is refused, whereas a row without a token would list a dead client.
	await recordAuthorizationGrant(connectDatabase(environment.DATABASE), {
		id: grantId,
		clientId,
		clientName,
		authorizationScope,
	})
	approved.headers.set("Location", redirectTo)
	return new Response(null, { status: 302, headers: approved.headers })
}

/** The consent page of the OAuth flow. It sits behind Access, so only a signed-in household member reaches it. */
export async function serveGrantConsent(
	environment: ModelContextEnvironment,
	request: Request,
	caller: Caller,
): Promise<Response> {
	if (!permits(caller, "administer")) return plainText("Authorizing a client requires the administer permission", 403)
	const oauth = getOAuthApi(authorizationServerOptions(new URL(request.url).origin), environment)
	try {
		return await (request.method === "POST"
			? decideConsent(environment, oauth, request)
			: showConsent(environment, oauth, request))
	} catch (error) {
		if (!(error instanceof AuthorizationError)) throw error
		// redirectTo exists only once the library has validated the client and its redirect URI.
		return error.redirectTo === undefined ? plainText(error.description, 400) : Response.redirect(error.redirectTo, 302)
	}
}
