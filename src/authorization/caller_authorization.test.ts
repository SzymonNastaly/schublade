import { expect, test } from "vitest"
import { permits } from "./caller_authorization"
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
