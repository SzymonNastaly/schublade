import { applyD1Migrations, env } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { documents, householdMembers } from "../database/schema"
import { queryDocumentListing } from "./document_listing"

test("queryDocumentListing filtered by a person lists only archived documents", async () => {
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	const memberId = "2e7f9a1b-3c4d-4e5f-8a6b-7c8d9e0f1a2b"
	await database.insert(householdMembers).values({ id: memberId, displayName: "Jonas Becker", addresseeNames: [] })
	const documentOf = (id: string, status: "archived" | "classifying", personMemberId: string | null) => ({
		id,
		storageObjectKey: `documents/${id}/original.pdf`,
		mimeType: "application/pdf",
		byteSize: 1024,
		status,
		personMemberId,
	})
	await database
		.insert(documents)
		.values([
			documentOf("a1000000-0000-4000-8000-000000000001", "archived", memberId),
			documentOf("a1000000-0000-4000-8000-000000000002", "classifying", memberId),
			documentOf("a1000000-0000-4000-8000-000000000003", "archived", null),
			documentOf("a1000000-0000-4000-8000-000000000004", "classifying", null),
		])

	const [memberListing, householdListing] = await Promise.all([
		queryDocumentListing(database, { person: memberId }),
		queryDocumentListing(database, { person: "household" }),
	])

	expect({
		member: memberListing.map((document) => document.id),
		household: householdListing.map((document) => document.id),
	}).toEqual({
		member: ["a1000000-0000-4000-8000-000000000001"],
		household: ["a1000000-0000-4000-8000-000000000003"],
	})
})
