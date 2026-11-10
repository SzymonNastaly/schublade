import { applyD1Migrations, env, reset } from "cloudflare:test"
import { asc } from "drizzle-orm"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "./client"
import { categories, documentTags, documents, extractedFields, senders, tags } from "./schema"

const invoiceCategoryId = "0b1c2d3e-4f50-4a61-8b72-c3d4e5f60718"
const unknownCategoryId = "1c2d3e4f-5061-4b72-9c83-d4e5f6071829"
const unknownSenderId = "2d3e4f50-6172-4c83-ad94-e5f60718293a"
const utilitySenderId = "3e4f5061-7283-4d94-bea5-f60718293a4b"
const electricityTagId = "4f506172-8394-4ea5-8fb6-0718293a4b5c"
const invoiceId = "50617283-94a5-4fb6-90c7-18293a4b5c6d"
const unreadableId = "61728394-a5b6-40c7-a1d8-293a4b5c6d7e"
const classifyingId = "728394a5-b6c7-41d8-b2e9-3a4b5c6d7e8f"

// The rows as staging holds them under the schema of the first migration.
const stagingRows = [
	`INSERT INTO categories (id, name, normalized_name, expected_fields_json, created_at) VALUES
		('${invoiceCategoryId}', 'Invoice', 'invoice', '["amount","currency","due_date","iban","invoice_number"]', 1793000000),
		('${unknownCategoryId}', 'Unknown', 'unknown', '[]', 1793000100)`,
	`INSERT INTO senders (id, name, normalized_name, created_at) VALUES
		('${unknownSenderId}', 'Unknown', 'unknown', 1793000200),
		('${utilitySenderId}', 'Stadtwerke Talbrück GmbH', 'stadtwerke talbruck gmbh', 1793000300)`,
	`INSERT INTO tags (id, name, normalized_name, created_at) VALUES ('${electricityTagId}', 'strom', 'strom', 1793000400)`,
	`INSERT INTO documents
		(id, title, document_date, sender_id, category_id, storage_object_key, mime_type, byte_size, status, verification_reason, created_at, updated_at)
		VALUES
		('${invoiceId}', 'Stadtwerke Invoice', '2026-09-22', '${utilitySenderId}', '${invoiceCategoryId}', 'documents/${invoiceId}/original.pdf', 'application/pdf', 1024, 'archived', 'new_taxonomy_record', 1793100000, 1793100000),
		('${unreadableId}', 'Unreadable Letter', NULL, '${unknownSenderId}', '${unknownCategoryId}', 'documents/${unreadableId}/original.jpg', 'image/jpeg', 2048, 'archived', 'illegible_required_field', 1793100500, 1793100600),
		('${classifyingId}', NULL, NULL, NULL, NULL, 'documents/${classifyingId}/original.pdf', 'application/pdf', 512, 'classifying', NULL, 1793100900, 1793100900)`,
	`INSERT INTO extracted_fields (id, document_id, field_key, field_type, value_number, confidence_score) VALUES
		('83a4b5c6-d7e8-4f90-a1b2-c3d4e5f60718', '${invoiceId}', 'amount', 'number', 72.09, 0.94)`,
	`INSERT INTO document_tags (document_id, tag_id) VALUES ('${invoiceId}', '${electricityTagId}')`,
]

test("the migrations turn an archive written under the first schema into the current one", async () => {
	await reset()
	const migrations = inject("databaseMigrations")
	await applyD1Migrations(env.DATABASE, migrations.slice(0, 1))
	await env.DATABASE.batch(stagingRows.map((statement) => env.DATABASE.prepare(statement)))

	await applyD1Migrations(env.DATABASE, migrations)

	const database = connectDatabase(env.DATABASE)
	expect({
		appliedMigrations: migrations.map((migration) => migration.name),
		categories: await database.select().from(categories).orderBy(asc(categories.name)),
		senders: await database.select().from(senders).orderBy(asc(senders.name)),
		tags: await database.select().from(tags),
		documents: await database
			.select({
				id: documents.id,
				status: documents.status,
				updatedAt: documents.updatedAt,
				indexedAt: documents.indexedAt,
			})
			.from(documents)
			.orderBy(asc(documents.createdAt)),
		fields: await database
			.select({ documentId: extractedFields.documentId, valueNumber: extractedFields.valueNumber })
			.from(extractedFields),
		links: await database.select().from(documentTags),
	}).toEqual({
		appliedMigrations: [
			"0000_create_archive_tables.sql",
			"0001_record_taxonomy_confirmation.sql",
			"0002_record_indexed_revision.sql",
			"0003_record_document_failure_reason.sql",
			"0004_document_recognition_quarter_turns.sql",
			"0005_remove_taxonomy_confirmation_and_verification_reason.sql",
		],
		categories: [
			{
				id: invoiceCategoryId,
				name: "Invoice",
				normalizedName: "invoice",
				expectedFields: ["amount", "currency", "due_date", "iban", "invoice_number"],
				createdAt: new Date(1793000000_000),
			},
			{
				id: unknownCategoryId,
				name: "Unknown",
				normalizedName: "unknown",
				expectedFields: [],
				createdAt: new Date(1793000100_000),
			},
		],
		senders: [
			{
				id: utilitySenderId,
				name: "Stadtwerke Talbrück GmbH",
				normalizedName: "stadtwerke talbruck gmbh",
				createdAt: new Date(1793000300_000),
			},
			{ id: unknownSenderId, name: "Unknown", normalizedName: "unknown", createdAt: new Date(1793000200_000) },
		],
		tags: [
			{
				id: electricityTagId,
				name: "strom",
				normalizedName: "strom",
				colorHex: null,
				createdAt: new Date(1793000400_000),
			},
		],
		documents: [
			{
				id: invoiceId,
				status: "archived",
				updatedAt: new Date(1793100000_000),
				indexedAt: new Date(1793100000_000),
			},
			{
				id: unreadableId,
				status: "archived",
				updatedAt: new Date(1793100600_000),
				indexedAt: new Date(1793100600_000),
			},
			{
				id: classifyingId,
				status: "classifying",
				updatedAt: new Date(1793100900_000),
				indexedAt: null,
			},
		],
		fields: [{ documentId: invoiceId, valueNumber: 72.09 }],
		links: [{ documentId: invoiceId, tagId: electricityTagId }],
	})
})
