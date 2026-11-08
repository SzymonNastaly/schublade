import * as reactStart from "@tanstack/react-start"
import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test, vi } from "vitest"
import { createInMemorySearchIndex } from "../search/in_memory_search_index"
import type { AsyncLocalStorage } from "node:async_hooks"
import type { Caller, PermissionLevel } from "../authorization/caller_authorization"

// The TanStack Start compiler passes each handler as the client stub and as the server function.
// Vitest runs without that compiler, so the factory passes the handler as both. vi.mock would
// call AsyncLocalStorage.disable(), which workerd lacks, so the factory is spied on instead.
const createServerFn = reactStart.createServerFn
const compiled = <TBuilder extends object>(builder: TBuilder): TBuilder =>
	new Proxy(builder, {
		get: (target, property, receiver) => {
			const member: unknown = Reflect.get(target, property, receiver)
			if (typeof member !== "function") return member
			if (property === "handler") return (handler: unknown) => member.call(target, handler, handler)
			if (property === "validator") return (validator: unknown) => compiled(member.call(target, validator) as object)
			return member
		},
	})
vi.spyOn(reactStart, "createServerFn").mockImplementation((...parameters) => compiled(createServerFn(...parameters)))
const {
	countPendingVerificationItems,
	retrieveDocument,
	retrieveDocumentStatuses,
	retrieveVerificationItems,
	submitDocumentDeletion,
	submitDocumentIngestionRetry,
	submitDocumentRevision,
	submitTaxonomyConfirmation,
	submitTaxonomyConfirmations,
	submitTaxonomyDeletion,
	submitTaxonomyMerge,
	submitTaxonomyRename,
} = await import("./server_functions")

interface ServerFunction {
	__executeServer: (options: { data: unknown; method: string }) => Promise<{ result?: unknown; error?: unknown }>
}

/**
 * Runs a server function as TanStack Start runs one for a request: inside the start context,
 * with the context the Worker entry passed to the request handler, through the validator and
 * the handler.
 */
async function call(serverFunction: unknown, caller: Caller | undefined, data?: unknown) {
	const startStorage = (globalThis as unknown as Record<symbol, AsyncLocalStorage<unknown>>)[
		Symbol.for("tanstack-start:start-storage-context")
	]
	if (startStorage === undefined) throw new Error("TanStack Start did not create its start context storage")
	const outcome = await startStorage.run(
		{
			request: new Request("http://localhost/_serverFn"),
			executedRequestMiddlewares: new Set(),
			handlerType: "serverFn",
			contextAfterGlobalMiddlewares: caller === undefined ? {} : { caller },
		},
		() => (serverFunction as ServerFunction).__executeServer({ data, method: "POST" }),
	)
	return outcome.error instanceof Error ? outcome.error.message : outcome.result
}

const token = (level: PermissionLevel): Caller => ({ kind: "api_token", tokenId: `${level}-token`, scope: { level } })

const documentId = "9c1e5a37-2b4d-4f86-a0c3-7e5d9b1f2a64"
const recordId = "3b7f1d95-6e2a-4c48-8d07-1a9e5c3b7f20"

test("each server function of Pending verification and the document page refuses a caller below its level and admits one at it", async () => {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	Object.assign(env, { SEARCH_INDEX: createInMemorySearchIndex().searchIndex })
	const record = { kind: "sender", recordId }
	const cases = {
		retrieveVerificationItems: [retrieveVerificationItems, undefined, token("read"), undefined],
		countPendingVerificationItems: [countPendingVerificationItems, undefined, token("read"), undefined],
		retrieveDocument: [retrieveDocument, undefined, token("read"), { documentId }],
		retrieveDocumentStatuses: [retrieveDocumentStatuses, undefined, token("read"), { documentIds: [documentId] }],
		submitDocumentRevision: [submitDocumentRevision, token("ingest"), token("modify"), { documentId }],
		submitDocumentIngestionRetry: [submitDocumentIngestionRetry, token("ingest"), token("modify"), { documentId }],
		submitTaxonomyConfirmation: [submitTaxonomyConfirmation, token("ingest"), token("modify"), record],
		submitTaxonomyConfirmations: [
			submitTaxonomyConfirmations,
			token("ingest"),
			token("modify"),
			{ kind: "sender", recordIds: [recordId] },
		],
		submitTaxonomyRename: [submitTaxonomyRename, token("ingest"), token("modify"), { ...record, name: "Werkhof" }],
		submitTaxonomyMerge: [
			submitTaxonomyMerge,
			token("modify"),
			token("administer"),
			{ kind: "sender", sourceRecordId: documentId, targetRecordId: recordId },
		],
		submitDocumentDeletion: [submitDocumentDeletion, token("modify"), token("administer"), { documentId }],
		submitTaxonomyDeletion: [submitTaxonomyDeletion, token("modify"), { kind: "member_session" }, record],
	} as const

	const outcomes: Record<string, { below: unknown; at: unknown }> = {}
	for (const [name, [serverFunction, belowLevel, atLevel, data]] of Object.entries(cases)) {
		outcomes[name] = {
			below: await call(serverFunction, belowLevel, data),
			at: await call(serverFunction, atLevel, data),
		}
	}

	expect(outcomes).toEqual({
		retrieveVerificationItems: { below: "This action requires the read permission", at: [] },
		countPendingVerificationItems: { below: "This action requires the read permission", at: 0 },
		retrieveDocument: { below: "This action requires the read permission", at: null },
		retrieveDocumentStatuses: { below: "This action requires the read permission", at: [] },
		submitDocumentRevision: {
			below: "This action requires the modify permission",
			at: `Document ${documentId} does not exist`,
		},
		submitDocumentIngestionRetry: {
			below: "This action requires the modify permission",
			at: `Document ${documentId} has not failed, so it cannot be retried`,
		},
		submitTaxonomyConfirmation: {
			below: "This action requires the modify permission",
			at: `The sender ${recordId} does not exist`,
		},
		submitTaxonomyConfirmations: { below: "This action requires the modify permission", at: 0 },
		submitTaxonomyRename: {
			below: "This action requires the modify permission",
			at: `The sender ${recordId} does not exist`,
		},
		submitTaxonomyMerge: {
			below: "This action requires the administer permission",
			at: `The sender ${recordId} to merge into does not exist`,
		},
		submitDocumentDeletion: { below: "This action requires the administer permission", at: undefined },
		submitTaxonomyDeletion: { below: "This action requires the administer permission", at: undefined },
	})
})
