import { expect, test } from "vitest"
import {
	accessProtectedHostnames,
	mailRecordsBlockingEmailRouting,
	modelContextProtocolDestinations,
	routesAddressToWorker,
	zoneNameCandidates,
} from "./provisioning_requests"

test("accessProtectedHostnames keeps workers.dev behind Access until the Worker stops serving it", () => {
	const workerHostname = "schublade-staging.household.workers.dev"
	expect({
		withoutCustomHostname: accessProtectedHostnames({
			workerHostname,
			customHostname: undefined,
			workersDevEnabled: true,
		}),
		beforeTheRouteMoves: accessProtectedHostnames({
			workerHostname,
			customHostname: "staging.schublade.org",
			workersDevEnabled: true,
		}),
		afterTheRouteMoves: accessProtectedHostnames({
			workerHostname,
			customHostname: "staging.schublade.org",
			workersDevEnabled: false,
		}),
	}).toEqual({
		withoutCustomHostname: ["schublade-staging.household.workers.dev"],
		beforeTheRouteMoves: ["staging.schublade.org", "schublade-staging.household.workers.dev"],
		afterTheRouteMoves: ["staging.schublade.org"],
	})
})

test("zoneNameCandidates lists the zones that could hold a hostname, the most specific first", () => {
	expect({
		subdomain: zoneNameCandidates("staging.schublade.org"),
		apex: zoneNameCandidates("schublade.org"),
	}).toEqual({ subdomain: ["staging.schublade.org", "schublade.org"], apex: ["schublade.org"] })
})

test("routesAddressToWorker accepts only an enabled literal rule that sends the address to this Worker", () => {
	const rule = {
		enabled: true,
		matchers: [{ type: "literal", field: "to", value: "documents@schublade.org" }],
		actions: [{ type: "worker", value: ["schublade-staging"] }],
	}
	expect([
		routesAddressToWorker(rule, "Documents@schublade.org", "schublade-staging"),
		routesAddressToWorker({ ...rule, enabled: false }, "documents@schublade.org", "schublade-staging"),
		routesAddressToWorker(rule, "documents@schublade.org", "schublade"),
		routesAddressToWorker(
			{ ...rule, actions: [{ type: "forward", value: ["person@example.com"] }] },
			"documents@schublade.org",
			"schublade-staging",
		),
	]).toEqual([true, false, false, false])
})

test("mailRecordsBlockingEmailRouting names the apex MX records Email Routing did not create unless replacing them is allowed", () => {
	const records = [
		{ name: "schublade.org", content: "route1.mx.cloudflare.net", priority: 13 },
		{ name: "schublade.org", content: "mx01.mail.example.net", priority: 10 },
		{ name: "Schublade.org", content: "MX02.mail.example.net.", priority: 20 },
		{ name: "bounces.schublade.org", content: "feedback-smtp.example.com", priority: 10 },
	]
	expect({
		withoutPermission: mailRecordsBlockingEmailRouting("schublade.org", records, { replaceMailRecords: false }),
		withPermission: mailRecordsBlockingEmailRouting("schublade.org", records, { replaceMailRecords: true }),
		onlyEmailRouting: mailRecordsBlockingEmailRouting(
			"schublade.org",
			[
				{ name: "schublade.org", content: "route1.mx.cloudflare.net", priority: 13 },
				{ name: "schublade.org", content: "route2.mx.cloudflare.net", priority: 86 },
				{ name: "schublade.org", content: "route3.mx.cloudflare.net", priority: 24 },
			],
			{ replaceMailRecords: false },
		),
	}).toEqual({
		withoutPermission: [
			{ name: "schublade.org", content: "mx01.mail.example.net", priority: 10 },
			{ name: "Schublade.org", content: "MX02.mail.example.net.", priority: 20 },
		],
		withPermission: [],
		onlyEmailRouting: [],
	})
})

test("modelContextProtocolDestinations lists every path a client reaches without an Access session, and not the consent page", () => {
	expect(modelContextProtocolDestinations("staging.example.org")).toEqual([
		"staging.example.org/mcp",
		"staging.example.org/oauth/token",
		"staging.example.org/oauth/register",
		"staging.example.org/.well-known/oauth-*",
	])
})
