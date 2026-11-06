import { expect, test } from "vitest"
import { authorizeOperation, permits } from "./caller_authorization"
import type { Caller, PermissionLevel } from "./caller_authorization"

const ingestToken: Caller = { kind: "api_token", tokenId: "token-1", scope: { level: "ingest" } }
const readToken: Caller = { kind: "api_token", tokenId: "token-2", scope: { level: "read" } }
const mail: Caller = { kind: "inbound_mail", senderAddress: "member@example.com" }
const member: Caller = { kind: "member_session" }

test("permits a caller every level up to its own and no level above it", () => {
	const levels: Array<PermissionLevel> = ["read", "ingest", "modify", "administer"]
	const grants = (caller: Caller) => levels.filter((level) => permits(caller, level))

	expect({
		ingestToken: grants(ingestToken),
		readToken: grants(readToken),
		mail: grants(mail),
		member: grants(member),
	}).toEqual({
		ingestToken: ["read", "ingest"],
		readToken: ["read"],
		mail: ["read", "ingest"],
		member: ["read", "ingest", "modify", "administer"],
	})
})

test("authorizeOperation admits a modify token to revisions and reserves merging and deletion for administer", () => {
	const modifyToken: Caller = { kind: "api_token", tokenId: "token-3", scope: { level: "modify" } }
	const operations = [
		"readArchive",
		"reviseDocument",
		"confirmTaxonomyRecord",
		"renameTaxonomyRecord",
		"mergeTaxonomyRecords",
		"deleteDocument",
		"deleteTaxonomyRecord",
		"administerApiTokens",
	] as const
	const refusals = (context: unknown) =>
		Object.fromEntries(
			operations.map((operation) => {
				try {
					authorizeOperation(context, operation)
					return [operation, "admitted"]
				} catch (error) {
					return [operation, error instanceof Error ? error.message : String(error)]
				}
			}),
		)

	expect(refusals({ caller: modifyToken })).toEqual({
		readArchive: "admitted",
		reviseDocument: "admitted",
		confirmTaxonomyRecord: "admitted",
		renameTaxonomyRecord: "admitted",
		mergeTaxonomyRecords: "This action requires the administer permission",
		deleteDocument: "This action requires the administer permission",
		deleteTaxonomyRecord: "This action requires the administer permission",
		administerApiTokens: "This action requires the administer permission",
	})
	expect([readToken, member, undefined].map((caller) => refusals({ caller }).reviseDocument)).toEqual([
		"This action requires the modify permission",
		"admitted",
		"This action requires the modify permission",
	])
})
