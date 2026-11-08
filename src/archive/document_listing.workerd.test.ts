import { applyD1Migrations, env } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { categories, documentTags, documents, householdMembers, senders, tags } from "../database/schema"
import { queryArchiveFacets, queryDocumentListing, queryDocumentStatuses } from "./document_listing"

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

test("queryDocumentListing lists a document without a date first, then the newest document date", async () => {
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	const memberId = "3f8a0b2c-4d5e-4f60-9b7c-8d9e0f1a2b3c"
	await database.insert(householdMembers).values({ id: memberId, displayName: "Lena Becker", addresseeNames: [] })
	const documentOf = (id: string, documentDate: string | null) => ({
		id,
		storageObjectKey: `documents/${id}/original.pdf`,
		mimeType: "application/pdf",
		byteSize: 1024,
		status: "archived" as const,
		personMemberId: memberId,
		documentDate,
	})
	await database
		.insert(documents)
		.values([
			documentOf("b1000000-0000-4000-8000-000000000001", "2026-03-12"),
			documentOf("b1000000-0000-4000-8000-000000000002", null),
			documentOf("b1000000-0000-4000-8000-000000000003", "2026-10-31"),
		])

	const listing = await queryDocumentListing(database, { person: memberId })

	expect(listing.map((document) => document.id)).toEqual([
		"b1000000-0000-4000-8000-000000000002",
		"b1000000-0000-4000-8000-000000000003",
		"b1000000-0000-4000-8000-000000000001",
	])
})

test("queryDocumentStatuses reports the given documents with their failure reason and whether they need review", async () => {
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	const senderId = "c1000000-0000-4000-8000-000000000001"
	await database.insert(senders).values({ id: senderId, name: "Werkhof", normalizedName: "werkhof" })
	const statusDocument = (id: string, status: "archived" | "failed" | "classifying") => ({
		id,
		storageObjectKey: `documents/${id}/original.pdf`,
		mimeType: "application/pdf",
		byteSize: 1024,
		status,
	})
	const newSenderId = "c2000000-0000-4000-8000-000000000001"
	const settledId = "c2000000-0000-4000-8000-000000000002"
	const failedId = "c2000000-0000-4000-8000-000000000003"
	await database
		.insert(documents)
		.values([
			{ ...statusDocument(newSenderId, "archived"), title: "Werkhof Receipt", senderId },
			{ ...statusDocument(settledId, "archived"), title: "Plain Receipt" },
			{ ...statusDocument(failedId, "failed"), failureReason: "page_limit_exceeded" },
			statusDocument("c2000000-0000-4000-8000-000000000004", "classifying"),
		])

	const records = await queryDocumentStatuses(database, [newSenderId, settledId, failedId])

	expect(records.sort((first, second) => first.documentId.localeCompare(second.documentId))).toEqual([
		{ documentId: newSenderId, title: "Werkhof Receipt", status: "archived", failureReason: null, needsReview: true },
		{ documentId: settledId, title: "Plain Receipt", status: "archived", failureReason: null, needsReview: false },
		{ documentId: failedId, title: null, status: "failed", failureReason: "page_limit_exceeded", needsReview: false },
	])
})

test("queryArchiveFacets counts only the archived documents of each value", async () => {
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	await database.delete(documents)
	const memberId = "d1000000-0000-4000-8000-000000000001"
	const senderId = "d2000000-0000-4000-8000-000000000001"
	const senderWithoutArchivedDocumentsId = "d2000000-0000-4000-8000-000000000002"
	const categoryId = "d3000000-0000-4000-8000-000000000001"
	const tagId = "d4000000-0000-4000-8000-000000000001"
	await database.insert(householdMembers).values({ id: memberId, displayName: "Ida Berg", addresseeNames: [] })
	await database.insert(senders).values([
		{ id: senderId, name: "Nordkabel", normalizedName: "nordkabel" },
		{ id: senderWithoutArchivedDocumentsId, name: "Stadtwerk", normalizedName: "stadtwerk" },
	])
	await database
		.insert(categories)
		.values({ id: categoryId, name: "Rechnung", normalizedName: "rechnung", expectedFields: ["amount"] })
	await database.insert(tags).values({ id: tagId, name: "tax-2026", normalizedName: "tax-2026" })
	const documentOf = (id: string, status: "archived" | "classifying") => ({
		id,
		storageObjectKey: `documents/${id}/original.pdf`,
		mimeType: "application/pdf",
		byteSize: 1024,
		status,
	})
	const taggedDocumentId = "d5000000-0000-4000-8000-000000000001"
	const unfinishedDocumentId = "d5000000-0000-4000-8000-000000000003"
	await database.insert(documents).values([
		{ ...documentOf(taggedDocumentId, "archived"), personMemberId: memberId, senderId, categoryId },
		{ ...documentOf("d5000000-0000-4000-8000-000000000002", "archived"), senderId },
		{
			...documentOf(unfinishedDocumentId, "classifying"),
			personMemberId: memberId,
			senderId: senderWithoutArchivedDocumentsId,
			categoryId,
		},
		documentOf("d5000000-0000-4000-8000-000000000004", "classifying"),
	])
	await database.insert(documentTags).values([
		{ documentId: taggedDocumentId, tagId },
		{ documentId: unfinishedDocumentId, tagId },
	])

	const facets = await queryArchiveFacets(database)

	const countOf = (options: Array<{ id: string; documentCount: number }>, id: string) =>
		options.find((option) => option.id === id)?.documentCount
	expect({
		member: countOf(facets.members, memberId),
		household: facets.householdDocumentCount,
		sender: countOf(facets.senders, senderId),
		senderWithoutArchivedDocuments: countOf(facets.senders, senderWithoutArchivedDocumentsId),
		category: countOf(facets.categories, categoryId),
		tag: countOf(facets.tags, tagId),
	}).toEqual({ member: 1, household: 1, sender: 2, senderWithoutArchivedDocuments: 0, category: 1, tag: 1 })
})
