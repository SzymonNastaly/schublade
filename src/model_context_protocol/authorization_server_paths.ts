export const MODEL_CONTEXT_PROTOCOL_PATH = "/mcp"
export const CONSENT_PATH = "/authorize"
export const TOKEN_PATH = "/oauth/token"
export const CLIENT_REGISTRATION_PATH = "/oauth/register"

/** The exact paths an OAuth client reaches without a browser session. The consent page is not one of them. */
export const ACCESS_BYPASSING_PATHS = [
	MODEL_CONTEXT_PROTOCOL_PATH,
	TOKEN_PATH,
	CLIENT_REGISTRATION_PATH,
	"/.well-known/oauth-authorization-server",
	`/.well-known/oauth-protected-resource${MODEL_CONTEXT_PROTOCOL_PATH}`,
]

/**
 * What the Access application bypasses, shared with the provisioning script. Access limits an
 * application URL to 63 characters, so one wildcard covers both metadata documents. It also covers
 * subpaths, so the Worker compares each exact pathname and keeps everything else behind Access.
 */
export const ACCESS_BYPASS_DESTINATIONS = [
	MODEL_CONTEXT_PROTOCOL_PATH,
	TOKEN_PATH,
	CLIENT_REGISTRATION_PATH,
	"/.well-known/oauth-*",
]
