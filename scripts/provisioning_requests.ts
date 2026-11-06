/**
 * The request bodies and decisions of `pnpm run provision` that depend only on its parameters,
 * kept apart from scripts/provision_environment.ts so they can be tested without Cloudflare.
 */

import { TOKEN_INGESTION_PATH } from "../src/ingestion/token_ingestion_path.ts"

export const ACCESS_SESSION_DURATION = "720h"

/** The zones that could hold a hostname, the most specific first: a.b.example.org, b.example.org, example.org. */
export function zoneNameCandidates(hostname: string): Array<string> {
	const labels = hostname.toLowerCase().split(".")
	return labels.slice(0, -1).map((_, index) => labels.slice(index).join("."))
}

/**
 * The hostnames the household Access application must cover. The workers.dev hostname stays
 * covered while the Worker still serves it, so moving to a custom hostname never leaves a
 * reachable hostname outside Access.
 */
export function accessProtectedHostnames(hostnames: {
	workerHostname: string
	customHostname: string | undefined
	workersDevEnabled: boolean
}): Array<string> {
	const { workerHostname, customHostname, workersDevEnabled } = hostnames
	if (customHostname === undefined) return [workerHostname]
	return workersDevEnabled ? [customHostname, workerHostname] : [customHostname]
}

export function accessApplicationBody(name: string, destinationUris: Array<string>, policyIdentifier: string) {
	return {
		type: "self_hosted",
		name,
		destinations: destinationUris.map((uri) => ({ type: "public", uri })),
		policies: [policyIdentifier],
		session_duration: ACCESS_SESSION_DURATION,
	}
}

/** Bypass lets requests to the ingestion path reach the Worker, which checks their bearer tokens. */
export function bypassPolicyBody(name: string) {
	return { name, decision: "bypass", include: [{ everyone: {} }] }
}

export function tokenIngestionDestination(hostname: string): string {
	return `${hostname}${TOKEN_INGESTION_PATH}`
}

interface EmailRoutingRule {
	enabled: boolean
	matchers: Array<{ type: string; field?: string | undefined; value?: string | undefined }>
	actions: Array<{ type: string; value?: Array<string> | undefined }>
}

/** True when an enabled rule sends exactly this address to this Worker. */
export function routesAddressToWorker(rule: EmailRoutingRule, address: string, workerName: string): boolean {
	return (
		rule.enabled &&
		rule.matchers.some(
			(matcher) =>
				matcher.type === "literal" && matcher.field === "to" && matcher.value?.toLowerCase() === address.toLowerCase(),
		) &&
		rule.actions.some((action) => action.type === "worker" && action.value?.includes(workerName) === true)
	)
}

// The MX hosts that Email Routing adds to the apex of a zone when it is enabled.
const EMAIL_ROUTING_MAIL_EXCHANGERS = new Set([
	"route1.mx.cloudflare.net",
	"route2.mx.cloudflare.net",
	"route3.mx.cloudflare.net",
])

interface MailExchangeRecord {
	name: string
	content: string
	priority?: number | undefined
}

/**
 * The MX records that stop `pnpm run provision` from enabling Email Routing: those at the apex of
 * the zone that point anywhere but Email Routing. Enabling Email Routing rewrites the apex MX and
 * SPF records, so the mail those records deliver would arrive at Cloudflare instead, unless the
 * operator allowed replacing them.
 */
export function mailRecordsBlockingEmailRouting(
	zoneName: string,
	records: Array<MailExchangeRecord>,
	{ replaceMailRecords }: { replaceMailRecords: boolean },
): Array<MailExchangeRecord> {
	if (replaceMailRecords) return []
	return records.filter(
		(record) =>
			record.name.toLowerCase() === zoneName.toLowerCase() &&
			!EMAIL_ROUTING_MAIL_EXCHANGERS.has(record.content.toLowerCase().replace(/\.$/, "")),
	)
}
