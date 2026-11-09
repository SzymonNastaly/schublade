import { sql } from "drizzle-orm"
import { index, integer, primaryKey, real, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core"
import { createInsertSchema } from "drizzle-zod"
import { z } from "zod"
import { authorizationScopeSchema } from "../authorization/caller_authorization"
import type { AuthorizationScope } from "../authorization/caller_authorization"

const identifier = () =>
	text("id")
		.primaryKey()
		.$defaultFn(() => crypto.randomUUID())

const creationTime = () =>
	integer("created_at", { mode: "timestamp" })
		.notNull()
		.default(sql`(unixepoch())`)

// Null while a record the classifier created awaits a member in Pending verification. A record
// that a member creates, confirms, renames, or merges into is confirmed.
const confirmationTime = () => integer("confirmed_at", { mode: "timestamp" })

// An email without a usable attachment is stored as awaiting_rendering until its workflow renders it.
const documentStatuses = [
	"awaiting_rendering",
	"processing",
	"extracting",
	"recognizing_text",
	"classifying",
	"archived",
	"failed",
] as const

/**
 * The updated_at of a document's next revision. It exceeds the previous value even within one
 * second, so an AI Search upload of an earlier revision never counts as current.
 */
export const succeedingModificationTime = () => sql`max(unixepoch(), updated_at + 1)`

// A new sender, category, or tag is a state of that record, not of the document, so documents
// store only the two reasons that belong to the document itself. See verification_assessment.ts.
const verificationReasons = ["illegible_required_field", "non_archival_attachment"] as const

const documentFailureReasons = [
	"unreadable_file",
	"page_limit_exceeded",
	"unreadable_page",
	"processing_error",
] as const

export type QuarterTurns = 0 | 1 | 2 | 3

const extractedFieldTypes = ["text", "number", "date"] as const

export const householdMembers = sqliteTable("household_members", {
	id: identifier(),
	displayName: text("display_name").notNull(),
	// Spellings of the member's name as printed on letters, such as "M. Wisniewska".
	addresseeNames: text("addressee_names_json", { mode: "json" }).$type<Array<string>>().notNull(),
	createdAt: creationTime(),
})

export const senders = sqliteTable(
	"senders",
	{
		id: identifier(),
		name: text("name").notNull(),
		normalizedName: text("normalized_name").notNull(),
		createdAt: creationTime(),
		confirmedAt: confirmationTime(),
	},
	(table) => [uniqueIndex("senders_normalized_name_index").on(table.normalizedName)],
)

export const categories = sqliteTable(
	"categories",
	{
		id: identifier(),
		name: text("name").notNull(),
		normalizedName: text("normalized_name").notNull(),
		// Field keys the classifier extracts for this category, such as "amount" and "iban".
		expectedFields: text("expected_fields_json", { mode: "json" }).$type<Array<string>>().notNull(),
		createdAt: creationTime(),
		confirmedAt: confirmationTime(),
	},
	(table) => [uniqueIndex("categories_normalized_name_index").on(table.normalizedName)],
)

export const tags = sqliteTable(
	"tags",
	{
		id: identifier(),
		name: text("name").notNull(),
		normalizedName: text("normalized_name").notNull(),
		colorHex: text("color_hex"),
		createdAt: creationTime(),
		confirmedAt: confirmationTime(),
	},
	(table) => [uniqueIndex("tags_normalized_name_index").on(table.normalizedName)],
)

export const documents = sqliteTable(
	"documents",
	{
		id: identifier(),
		title: text("title"),
		// ISO 8601 calendar date printed on the document, not the ingestion time.
		documentDate: text("document_date"),
		senderId: text("sender_id").references(() => senders.id),
		categoryId: text("category_id").references(() => categories.id),
		// Null assigns the document to the whole household.
		personMemberId: text("person_member_id").references(() => householdMembers.id),
		summary: text("summary"),
		storageObjectKey: text("storage_object_key").notNull(),
		mimeType: text("mime_type").notNull(),
		byteSize: integer("byte_size").notNull(),
		pageCount: integer("page_count"),
		status: text("status", { enum: documentStatuses }).notNull().default("processing"),
		verificationReason: text("verification_reason", { enum: verificationReasons }),
		// Null unless the status is failed.
		failureReason: text("failure_reason", { enum: documentFailureReasons }),
		recognitionQuarterTurns: integer("recognition_quarter_turns").$type<QuarterTurns>().notNull().default(0),
		createdAt: creationTime(),
		updatedAt: integer("updated_at", { mode: "timestamp" })
			.notNull()
			.default(sql`(unixepoch())`)
			.$onUpdateFn(succeedingModificationTime),
		// The updated_at of the revision that AI Search holds, null until the index step uploads
		// the document. A document whose updated_at is later awaits a new upload.
		indexedAt: integer("indexed_at", { mode: "timestamp" }),
	},
	(table) => [
		uniqueIndex("documents_storage_object_key_index").on(table.storageObjectKey),
		index("documents_document_date_index").on(table.documentDate),
		index("documents_sender_id_index").on(table.senderId),
		index("documents_category_id_index").on(table.categoryId),
		index("documents_person_member_id_index").on(table.personMemberId),
		index("documents_status_index").on(table.status),
	],
)

export const documentTags = sqliteTable(
	"document_tags",
	{
		documentId: text("document_id")
			.notNull()
			.references(() => documents.id, { onDelete: "cascade" }),
		tagId: text("tag_id")
			.notNull()
			.references(() => tags.id, { onDelete: "cascade" }),
	},
	(table) => [
		primaryKey({ columns: [table.documentId, table.tagId] }),
		index("document_tags_tag_id_index").on(table.tagId),
	],
)

export const extractedFields = sqliteTable(
	"extracted_fields",
	{
		id: identifier(),
		documentId: text("document_id")
			.notNull()
			.references(() => documents.id, { onDelete: "cascade" }),
		fieldKey: text("field_key").notNull(),
		// Number fields fill value_number. Text and date fields fill value_text, dates as ISO 8601.
		fieldType: text("field_type", { enum: extractedFieldTypes }).notNull(),
		valueText: text("value_text"),
		valueNumber: real("value_number"),
		confidenceScore: real("confidence_score"),
	},
	(table) => [uniqueIndex("extracted_fields_document_field_index").on(table.documentId, table.fieldKey)],
)

export const apiTokens = sqliteTable(
	"api_tokens",
	{
		id: identifier(),
		description: text("description").notNull(),
		tokenSha256: text("token_sha256").notNull(),
		authorizationScope: text("authorization_scope_json", { mode: "json" }).$type<AuthorizationScope>().notNull(),
		lastUsedAt: integer("last_used_at", { mode: "timestamp" }),
		createdAt: creationTime(),
	},
	(table) => [uniqueIndex("api_tokens_token_sha256_index").on(table.tokenSha256)],
)

export const authorizationGrants = sqliteTable(
	"authorization_grants",
	{
		id: identifier(),
		clientId: text("client_id").notNull(),
		clientName: text("client_name").notNull(),
		authorizationScope: text("authorization_scope_json", { mode: "json" }).$type<AuthorizationScope>().notNull(),
		createdAt: creationTime(),
		revokedAt: integer("revoked_at", { mode: "timestamp" }),
	},
	(table) => [index("authorization_grants_client_id_index").on(table.clientId)],
)

// Insert schemas parse input that crosses a boundary. Each omits the identifier and the
// timestamps that the database or the Worker assigns.
const managedColumns = { id: true, createdAt: true } as const
const names = z.array(z.string().trim().min(1)).min(1)

export const householdMemberInsertSchema = createInsertSchema(householdMembers, {
	displayName: (schema) => schema.trim().min(1),
	addresseeNames: names,
}).omit(managedColumns)

export const senderInsertSchema = createInsertSchema(senders, {
	name: (schema) => schema.trim().min(1),
}).omit(managedColumns)

export const categoryInsertSchema = createInsertSchema(categories, {
	name: (schema) => schema.trim().min(1),
	expectedFields: z.array(z.string().min(1)),
}).omit(managedColumns)

export const tagInsertSchema = createInsertSchema(tags, {
	name: (schema) => schema.trim().min(1),
	colorHex: (schema) => schema.regex(/^#[0-9a-f]{6}$/),
}).omit(managedColumns)

export const documentInsertSchema = createInsertSchema(documents, {
	documentDate: z.iso.date(),
	byteSize: (schema) => schema.int().nonnegative(),
	pageCount: (schema) => schema.int().positive(),
}).omit({ ...managedColumns, updatedAt: true, indexedAt: true, recognitionQuarterTurns: true })

export const documentTagInsertSchema = createInsertSchema(documentTags)

export const extractedFieldInsertSchema = createInsertSchema(extractedFields, {
	confidenceScore: (schema) => schema.min(0).max(1),
}).omit({ id: true })

export const apiTokenInsertSchema = createInsertSchema(apiTokens, {
	tokenSha256: (schema) => schema.regex(/^[0-9a-f]{64}$/),
	authorizationScope: authorizationScopeSchema,
}).omit({ ...managedColumns, lastUsedAt: true })

export const authorizationGrantInsertSchema = createInsertSchema(authorizationGrants, {
	authorizationScope: authorizationScopeSchema,
}).omit({ ...managedColumns, revokedAt: true })
