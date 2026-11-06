import { expect, test } from "vitest"
import { accessProtectedHostnames, routesAddressToWorker, zoneNameCandidates } from "./provisioning_requests"

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
