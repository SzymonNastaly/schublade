import { OAuthProvider } from "@cloudflare/workers-oauth-provider"
import { serveArchiveTools } from "./archive_tools"
import { AUTHORIZATION_GRANT_LIFETIME_SECONDS } from "./authorization_grants"
import {
	CLIENT_REGISTRATION_PATH,
	CONSENT_PATH,
	MODEL_CONTEXT_PROTOCOL_PATH,
	TOKEN_PATH,
} from "./authorization_server_paths"
import type { OAuthProviderOptions } from "@cloudflare/workers-oauth-provider"

export type ModelContextEnvironment = Pick<Env, "DATABASE" | "DOCUMENT_STORAGE" | "OAUTH_KV" | "SEARCH_INDEX">

/** The consent page, not the OAuth scope, narrows a grant. Every grant is read-only. */
export const GRANTED_OAUTH_SCOPES = ["read"]

/** Schublade does not record which member is signed in, so the household owns every grant. */
export const HOUSEHOLD_GRANT_SUBJECT = "household"

// Registration needs no credential, so this caps what a stranger can store in KV per request.
const MAXIMUM_CLIENT_METADATA_CHARACTERS = 8192

/** Tokens are bound to the origin that clients connect to, which is the origin of the request. */
export function authorizationServerOptions(origin: string): OAuthProviderOptions<ModelContextEnvironment> {
	return {
		apiRoute: MODEL_CONTEXT_PROTOCOL_PATH,
		apiHandler: { fetch: serveArchiveTools },
		// The dispatcher sends only the provider's own paths here, so nothing reaches this handler.
		defaultHandler: { fetch: () => new Response("Not found", { status: 404 }) },
		authorizeEndpoint: CONSENT_PATH,
		tokenEndpoint: TOKEN_PATH,
		clientRegistrationEndpoint: CLIENT_REGISTRATION_PATH,
		clientRegistrationCallback: ({ clientMetadata }) =>
			JSON.stringify(clientMetadata).length > MAXIMUM_CLIENT_METADATA_CHARACTERS
				? { description: "The client metadata is too large" }
				: undefined,
		refreshTokenTTL: AUTHORIZATION_GRANT_LIFETIME_SECONDS,
		scopesSupported: GRANTED_OAUTH_SCOPES,
		resourceMetadata: {
			resource: `${origin}${MODEL_CONTEXT_PROTOCOL_PATH}`,
			authorization_servers: [origin],
			resource_name: "Schublade document archive",
		},
	}
}

export function serveAuthorizationServer(
	request: Request,
	environment: ModelContextEnvironment,
	context: ExecutionContext,
): Promise<Response> {
	const { origin } = new URL(request.url)
	return new OAuthProvider(authorizationServerOptions(origin)).fetch(request, environment, context)
}
