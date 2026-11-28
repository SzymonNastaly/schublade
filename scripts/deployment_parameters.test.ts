import { expect, test } from "vitest"
import { parseDevelopmentParameters, requireProvisioned, workerNameToProvision } from "./deployment_parameters"

test("requireProvisioned refuses parameters without the resource identifiers and names each one", () => {
	expect(() => requireProvisioned({ workerName: "schublade-staging", documentStorageBucketName: "documents" })).toThrow(
		"schublade.deploy.json does not name databaseIdentifier, searchInstanceName, authorizationStateNamespaceIdentifier. Run `pnpm run provision` before building or deploying.",
	)
})

test("parseDevelopmentParameters accepts what a local mode reads and refuses a deployed environment's identifiers", () => {
	expect(parseDevelopmentParameters({ aiGatewayIdentifier: "default" })).toEqual({ aiGatewayIdentifier: "default" })
	expect(() => parseDevelopmentParameters({ databaseIdentifier: "d930e183-f594-47ed-bcd5-32fed409abfe" })).toThrow(
		/databaseIdentifier/,
	)
})

test("workerNameToProvision keeps a clone with the Worker it names", () => {
	expect({
		freshClone: workerNameToProvision(undefined, undefined),
		freshCloneNamed: workerNameToProvision("schublade-rehearsal", undefined),
		rerun: workerNameToProvision(undefined, "schublade-staging"),
		otherWorker: workerNameToProvision("schublade-rehearsal", "schublade-staging"),
	}).toEqual({
		freshClone: { kind: "named", workerName: "schublade" },
		freshCloneNamed: { kind: "named", workerName: "schublade-rehearsal" },
		rerun: { kind: "named", workerName: "schublade-staging" },
		otherWorker: {
			kind: "refused",
			reason:
				"This clone is the environment schublade-staging, so it cannot provision schublade-rehearsal. Provision another environment from another clone of the repository.",
		},
	})
})
