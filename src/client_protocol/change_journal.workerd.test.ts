import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import recording from "../../test_fixtures/inference_recordings/electricity_invoice_scanned.json"
import { queryDocumentListing } from "../archive/document_listing"
import { deleteDocument, documentRevisionSchema, reviseDocument } from "../archive/document_revision"
import { mergeTaxonomyRecords, renameTaxonomyRecord } from "../archive/taxonomy_maintenance"
import { connectDatabase } from "../database/client"
import {
	categories,
	documentTags,
	documents,
	extractedFields,
	householdMembers,
	journaledTables,
	senders,
	tablesNotReplicated,
	tags,
} from "../database/schema"
import { ingestDocument } from "../ingestion/document_ingestion"
import { acceptDocumentUpload } from "../ingestion/document_upload"
import { contentObjectKey } from "../ingestion/source_file"
import { createInMemorySearchIndex } from "../search/in_memory_search_index"
import { formatJournalCursor, parseJournalCursor, readJournalIdentity, readJournalPage } from "./change_journal"
import type { WorkflowStep } from "cloudflare:workers"
import type { ListedDocument } from "../archive/document_listing"
import type { AuthorizationScope } from "../authorization/caller_authorization"
import type { ArchiveDatabase } from "../database/client"
import type { JournalCursor, JournaledRecord, RecordChange } from "./change_journal"

// Each kind's identifiers ascend in the order written here, which is the order a page sends them in.
const jonas = { id: "10000000-0000-4000-8000-000000000001", displayName: "Jonas Becker" }
const insurer = { id: "20000000-0000-4000-8000-000000000001", name: "Allianz SE" }
const market = { id: "20000000-0000-4000-8000-000000000002", name: "Frischemarkt" }
const insurance = { id: "30000000-0000-4000-8000-000000000001", name: "Insurance" }
const receipts = { id: "30000000-0000-4000-8000-000000000002", name: "Receipt" }
const groceries = { id: "40000000-0000-4000-8000-000000000001", name: "groceries" }
const taxAlias = { id: "40000000-0000-4000-8000-000000000002", name: "steuer" }
const taxYear = { id: "40000000-0000-4000-8000-000000000003", name: "tax-2026" }
const policyId = "50000000-0000-4000-8000-000000000001"
const statementId = "50000000-0000-4000-8000-000000000002"
const receiptId = "50000000-0000-4000-8000-000000000003"

const wholeArchive: AuthorizationScope = { level: "read" }

/** An archive that held its records before the journal existed, so the journal's migration numbers them. */
async function prepareArchive() {
	await reset()
	const migrations = inject("databaseMigrations")
	await applyD1Migrations(env.DATABASE, migrations.slice(0, 8))
	const database = connectDatabase(env.DATABASE)
	await database.insert(householdMembers).values({ ...jonas, addresseeNames: ["J. Becker"] })
	await database.insert(senders).values([
		{ ...insurer, normalizedName: "allianz se" },
		{ ...market, normalizedName: "frischemarkt" },
	])
	await database.insert(categories).values([
		{ ...insurance, normalizedName: "insurance", expectedFields: ["policy_number"] },
		{ ...receipts, normalizedName: "receipt", expectedFields: ["amount"] },
	])
	await database.insert(tags).values([
		{ ...groceries, normalizedName: "groceries" },
		{ ...taxAlias, normalizedName: "steuer" },
		{ ...taxYear, normalizedName: "tax 2026" },
	])
	const archived = { mimeType: "application/pdf", byteSize: 1024, status: "archived" } as const
	await database.insert(documents).values([
		{
			...archived,
			id: policyId,
			title: "Allianz Liability Policy",
			documentDate: "2026-03-01",
			senderId: insurer.id,
			categoryId: insurance.id,
			personMemberId: jonas.id,
			storageObjectKey: `documents/${policyId}/original.pdf`,
		},
		{
			...archived,
			id: statementId,
			title: "Allianz Premium Statement 2026",
			documentDate: "2026-10-15",
			senderId: insurer.id,
			categoryId: insurance.id,
			storageObjectKey: `documents/${statementId}/original.pdf`,
		},
		{
			...archived,
			id: receiptId,
			title: "Frischemarkt Receipt",
			documentDate: "2026-10-31",
			senderId: market.id,
			categoryId: receipts.id,
			storageObjectKey: `documents/${receiptId}/original.pdf`,
		},
	])
	await database.insert(documentTags).values([
		{ documentId: policyId, tagId: taxAlias.id },
		{ documentId: statementId, tagId: taxAlias.id },
		{ documentId: statementId, tagId: taxYear.id },
		{ documentId: receiptId, tagId: groceries.id },
	])
	await database.insert(extractedFields).values([
		{ documentId: policyId, fieldKey: "policy_number", fieldType: "text", valueText: "HV-2291", confidenceScore: 0.9 },
		{ documentId: receiptId, fieldKey: "amount", fieldType: "number", valueNumber: 29.63, confidenceScore: 0.8 },
	])
	for (const documentId of [policyId, statementId, receiptId]) {
		await env.DOCUMENT_STORAGE.put(contentObjectKey(documentId), "# Extracted text")
	}
	await applyD1Migrations(env.DATABASE, migrations)
	return database
}

function describeChange(change: RecordChange): string {
	if (change.change === "removal") return `removal ${change.kind} ${change.id}`
	const { record } = change
	const name = record.kind === "document" ? record.title : "name" in record ? record.name : record.displayName
	return `${record.kind} ${name}`
}

/** What a client keeps: the records of the pages it applied and the cursor of the last one. */
interface Replica {
	cursor: JournalCursor | undefined
	records: Map<string, JournaledRecord>
}

/** Applies every page after the replica's cursor and returns the changes in the order they arrived. */
async function follow(database: ArchiveDatabase, scope: AuthorizationScope, replica: Replica): Promise<Array<string>> {
	const received: Array<string> = []
	for (;;) {
		const outcome = await readJournalPage(database, scope, replica.cursor, 2)
		if (outcome.kind !== "page") throw new Error(`The cursor was refused: ${outcome.reason}`)
		for (const change of outcome.page.changes) {
			received.push(describeChange(change))
			if (change.change === "upsert") replica.records.set(`${change.record.kind} ${change.record.id}`, change.record)
			else replica.records.delete(`${change.kind} ${change.id}`)
		}
		replica.cursor = outcome.page.nextCursor
		if (outcome.page.remainingEntries === 0) return received
	}
}

/** The listing as a client derives it from its replica alone, in the order of the document identifiers. */
function listedBy({ records }: Replica): Array<ListedDocument> {
	const named = (kind: JournaledRecord["kind"], id: string | null) => {
		const record = id === null ? undefined : records.get(`${kind} ${id}`)
		if (record === undefined || record.kind === "document") return null
		return record.kind === "household_member" ? record.displayName : record.name
	}
	return [...records.values()]
		.flatMap((record) => (record.kind === "document" ? [record] : []))
		.sort((left, right) => left.id.localeCompare(right.id))
		.map((document) => {
			const personMemberId = document.person.kind === "member" ? document.person.memberId : null
			return {
				id: document.id,
				status: document.status,
				title: document.title,
				documentDate: document.documentDate,
				senderName: named("sender", document.senderId),
				categoryName: named("category", document.categoryId),
				personMemberId,
				personName: named("household_member", personMemberId),
				summary: document.summary,
				mimeType: document.mimeType,
				pageCount: document.pageCount,
				tagNames: document.tagIds.map((tagId) => named("tag", tagId) ?? "a tag the replica lacks").sort(),
				fields: document.fields.map(({ fieldKey, value, confidenceScore }) => ({
					fieldKey,
					value,
					confidence: confidenceScore,
				})),
			}
		})
}

async function listedByArchive(database: ArchiveDatabase, authorizationScope?: AuthorizationScope) {
	const listing = await queryDocumentListing(database, { authorizationScope })
	return listing.sort((left, right) => left.id.localeCompare(right.id))
}

const recordOrder = (left: JournaledRecord, right: JournaledRecord) =>
	`${left.kind} ${left.id}`.localeCompare(`${right.kind} ${right.id}`)

/** The household members, senders, categories, and tags of a replica of the whole archive. */
function taxonomyOf({ records }: Replica): Array<JournaledRecord> {
	return [...records.values()].filter((record) => record.kind !== "document").sort(recordOrder)
}

async function taxonomyOfArchive(database: ArchiveDatabase): Promise<Array<JournaledRecord>> {
	const [memberRows, senderRows, categoryRows, tagRows] = await database.batch([
		database.select({ id: householdMembers.id, displayName: householdMembers.displayName }).from(householdMembers),
		database.select({ id: senders.id, name: senders.name }).from(senders),
		database
			.select({ id: categories.id, name: categories.name, expectedFields: categories.expectedFields })
			.from(categories),
		database.select({ id: tags.id, name: tags.name, colorHex: tags.colorHex }).from(tags),
	])
	return [
		...memberRows.map((member) => ({ kind: "household_member" as const, ...member })),
		...senderRows.map((sender) => ({ kind: "sender" as const, ...sender })),
		...categoryRows.map((category) => ({ kind: "category" as const, ...category })),
		...tagRows.map((tag) => ({ kind: "tag" as const, ...tag })),
	].sort(recordOrder)
}

/** A raw statement on a row of one journaled table, and the records whose entries it must move. */
type JournaledWrite = [statement: string, movedRecords: Array<string>]

/**
 * An insert, an update, and a delete of each journaled table, run in this order on the rows of
 * the test below. A link or a field belongs to its document, and an update that moves one moves
 * both documents.
 */
const writesOfEachTable = {
	documents: [
		[
			"INSERT INTO documents (id, storage_object_key, mime_type, byte_size) VALUES ('d3', 'k3', 'application/pdf', 1)",
			["document d3"],
		],
		["UPDATE documents SET title = 'Revised' WHERE id = 'd3'", ["document d3"]],
		["DELETE FROM documents WHERE id = 'd3'", ["document d3"]],
	],
	document_tags: [
		["INSERT INTO document_tags (document_id, tag_id) VALUES ('d1', 't1')", ["document d1"]],
		["UPDATE document_tags SET document_id = 'd2' WHERE document_id = 'd1'", ["document d1", "document d2"]],
		["DELETE FROM document_tags WHERE document_id = 'd2'", ["document d2"]],
	],
	extracted_fields: [
		[
			"INSERT INTO extracted_fields (id, document_id, field_key, field_type) VALUES ('f1', 'd1', 'amount', 'number')",
			["document d1"],
		],
		["UPDATE extracted_fields SET document_id = 'd2' WHERE id = 'f1'", ["document d1", "document d2"]],
		["DELETE FROM extracted_fields WHERE id = 'f1'", ["document d2"]],
	],
	household_members: [
		[
			"INSERT INTO household_members (id, display_name, addressee_names_json) VALUES ('m1', 'Jonas', '[]')",
			["household_member m1"],
		],
		["UPDATE household_members SET display_name = 'Jonas Becker' WHERE id = 'm1'", ["household_member m1"]],
		["DELETE FROM household_members WHERE id = 'm1'", ["household_member m1"]],
	],
	senders: [
		["INSERT INTO senders (id, name, normalized_name) VALUES ('s1', 'Allianz', 'allianz')", ["sender s1"]],
		["UPDATE senders SET name = 'Allianz SE' WHERE id = 's1'", ["sender s1"]],
		["DELETE FROM senders WHERE id = 's1'", ["sender s1"]],
	],
	categories: [
		[
			"INSERT INTO categories (id, name, normalized_name, expected_fields_json) VALUES ('c1', 'Receipt', 'receipt', '[]')",
			["category c1"],
		],
		["UPDATE categories SET name = 'Receipts' WHERE id = 'c1'", ["category c1"]],
		["DELETE FROM categories WHERE id = 'c1'", ["category c1"]],
	],
	tags: [
		["INSERT INTO tags (id, name, normalized_name) VALUES ('t2', 'tax', 'tax')", ["tag t2"]],
		["UPDATE tags SET name = 'Tax' WHERE id = 't2'", ["tag t2"]],
		["DELETE FROM tags WHERE id = 't2'", ["tag t2"]],
	],
} satisfies Record<
	keyof typeof journaledTables,
	[insert: JournaledWrite, update: JournaledWrite, deletion: JournaledWrite]
>

test("every table is journaled or listed as not replicated, and every write to a journaled row moves its record's entry", async () => {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	await env.DATABASE.batch(
		[
			"INSERT INTO documents (id, storage_object_key, mime_type, byte_size) VALUES ('d1', 'k1', 'application/pdf', 1), ('d2', 'k2', 'application/pdf', 1)",
			"INSERT INTO tags (id, name, normalized_name) VALUES ('t1', 'groceries', 'groceries')",
		].map((statement) => env.DATABASE.prepare(statement)),
	)

	const { results: tables } = await env.DATABASE.prepare(
		"SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> 'd1_migrations'",
	).all<{ name: string }>()
	const writes = (Object.keys(journaledTables) as Array<keyof typeof journaledTables>).flatMap(
		(table) => writesOfEachTable[table],
	)
	const movedByEachWrite: Array<JournaledWrite> = []
	for (const [statement] of writes) {
		const previousHighest = await env.DATABASE.prepare("SELECT max(sequence_number) FROM change_journal").first<number>(
			"max(sequence_number)",
		)
		await env.DATABASE.prepare(statement).run()
		const { results: moved } = await env.DATABASE.prepare(
			"SELECT record_kind || ' ' || record_identifier AS record FROM change_journal WHERE sequence_number > ? ORDER BY record",
		)
			.bind(previousHighest)
			.all<{ record: string }>()
		movedByEachWrite.push([statement, moved.map(({ record }) => record)])
	}

	expect({ tables: tables.map((table) => table.name).sort(), movedByEachWrite }).toEqual({
		tables: [...Object.keys(journaledTables), ...tablesNotReplicated].sort(),
		movedByEachWrite: writes,
	})
})

test("a client that pages from any earlier cursor ends with the documents the listing reports and every record of the taxonomy tables", async () => {
	const database = await prepareArchive()
	const { searchIndex } = createInMemorySearchIndex()
	const archive = { database, storage: env.DOCUMENT_STORAGE, searchIndex }
	// The recorded Workers AI responses of the fixture, so the ingestion makes no billed request.
	const ingestionEnvironment = {
		...env,
		AI_RUNTIME: {
			toMarkdown: () => Promise.resolve(recording.markdownConversion),
			run: (model: string) =>
				Promise.resolve(
					{
						"@cf/moondream/moondream3.1-9B-A2B": new Response(recording.textRecognitionEventStream).body,
						"@cf/cloudflare/clairic-flash": recording.classificationResponse,
						"@cf/cloudflare/clef-flash": recording.personAssignmentResponse,
					}[model],
				),
		} as unknown as Ai,
		CLASSIFICATION_MODEL: "@cf/cloudflare/clairic-flash",
		PERSON_ASSIGNMENT_MODEL: "@cf/cloudflare/clef-flash",
		SEARCH_INDEX: searchIndex,
		DOCUMENT_INGESTION_WORKFLOW: { create: () => Promise.resolve() } as unknown as Workflow,
	}
	const step = {
		do: (_name: string, _configuration: unknown, callback: () => Promise<unknown>) => callback(),
	} as unknown as Pick<WorkflowStep, "do">
	let invoiceId = ""
	const writes = [
		async () => {
			const upload = await acceptDocumentUpload(ingestionEnvironment, new File([scannedInvoice], "invoice.pdf"))
			if (upload.kind !== "accepted") throw new Error(`The upload was ${upload.kind}`)
			invoiceId = upload.documentId
		},
		() => ingestDocument(step, ingestionEnvironment, invoiceId),
		() =>
			reviseDocument(
				archive,
				documentRevisionSchema.parse({
					documentId: policyId,
					senderName: "Allianz Versicherungs-AG",
					personMemberId: null,
					tagNames: ["steuer", "liability"],
					fields: { policy_number: null, amount: 89.9 },
				}),
			),
		// Rewrites the journal's newest entry, which a client has read. Only AUTOINCREMENT numbers it above that cursor.
		() =>
			reviseDocument(
				archive,
				documentRevisionSchema.parse({ documentId: policyId, title: "Allianz Liability Policy 2026" }),
			),
		() => mergeTaxonomyRecords(database, { kind: "tag", sourceRecordId: taxAlias.id, targetRecordId: taxYear.id }),
		() => renameTaxonomyRecord(database, { kind: "sender", recordId: market.id, name: "Frischemarkt Talbrück GmbH" }),
		() => deleteDocument(archive, statementId),
	]

	const firstPage = await readJournalPage(database, wholeArchive, undefined, 2)
	// One replica follows every write. A copy of it stays behind after each one, at that cursor.
	const current: Replica = { cursor: undefined, records: new Map() }
	const replicas: Array<Replica> = [{ cursor: undefined, records: new Map() }]
	const receivedAfterEachWrite: Array<Array<string>> = []
	await follow(database, wholeArchive, current)
	for (const write of writes) {
		replicas.push(structuredClone(current))
		await write()
		receivedAfterEachWrite.push(await follow(database, wholeArchive, current))
		expect({ listing: listedBy(current), taxonomy: taxonomyOf(current) }).toEqual({
			listing: await listedByArchive(database),
			taxonomy: await taxonomyOfArchive(database),
		})
	}
	const laggingCursor = replicas[1]?.cursor
	const repeatedPages = [
		await readJournalPage(database, wholeArchive, laggingCursor, 2),
		await readJournalPage(database, wholeArchive, laggingCursor, 2),
	]
	const receivedFromTheStart = await follow(database, wholeArchive, replicas[0] ?? current)
	for (const replica of replicas.slice(1)) await follow(database, wholeArchive, replica)

	const listing = await listedByArchive(database)
	expect({
		// The migration numbered the documents newest first, each page with the records its documents refer to.
		firstPage: firstPage.kind === "page" && firstPage.page.changes.map(describeChange),
		afterTheUpload: receivedAfterEachWrite[0],
		afterTheDeletion: receivedAfterEachWrite.at(-1),
		statementEverSentFromTheStart: receivedFromTheStart.includes("document Allianz Premium Statement 2026"),
		// The uploaded invoice has a random identifier, so its place in the listing varies.
		titles: listing.map((document) => document.title).sort(),
	}).toEqual({
		firstPage: [
			"sender Allianz SE",
			"sender Frischemarkt",
			"category Insurance",
			"category Receipt",
			"tag groceries",
			"tag steuer",
			"tag tax-2026",
			"document Frischemarkt Receipt",
			"document Allianz Premium Statement 2026",
		],
		afterTheUpload: ["document null"],
		afterTheDeletion: ["removal document 50000000-0000-4000-8000-000000000002"],
		statementEverSentFromTheStart: false,
		titles: [
			"Allianz Liability Policy 2026",
			"Frischemarkt Receipt",
			"Stadtwerke Talbrück GmbH Gas invoice September 2026",
		],
	})
	expect(repeatedPages[0]).toEqual(repeatedPages[1])
	const taxonomy = await taxonomyOfArchive(database)
	for (const replica of replicas) {
		expect({ listing: listedBy(replica), taxonomy: taxonomyOf(replica) }).toEqual({ listing, taxonomy })
	}
})

test("a restricted client receives only what its scope admits, and a removal for what leaves it", async () => {
	const database = await prepareArchive()
	const { searchIndex } = createInMemorySearchIndex()
	const insuranceOnly: AuthorizationScope = { level: "read", allowedCategories: [insurance.id] }
	const replica: Replica = { cursor: undefined, records: new Map() }
	const upserts = (received: Array<string>) =>
		[...new Set(received)].filter((change) => !change.startsWith("removal")).sort()

	const filled = await follow(database, insuranceOnly, replica)
	await reviseDocument(
		{ database, storage: env.DOCUMENT_STORAGE, searchIndex },
		documentRevisionSchema.parse({ documentId: policyId, categoryName: "Receipt" }),
	)
	const afterThePolicyLeft = await follow(database, insuranceOnly, replica)
	// The rename writes the sender first and its documents after it, so a page of one entry holds the sender alone.
	await renameTaxonomyRecord(database, { kind: "sender", recordId: insurer.id, name: "Allianz Versicherung SE" })
	const insurerAlone = await readJournalPage(database, insuranceOnly, replica.cursor, 1)
	await renameTaxonomyRecord(database, { kind: "sender", recordId: market.id, name: "Frischemarkt Talbrück GmbH" })
	const marketAlone = await readJournalPage(
		database,
		insuranceOnly,
		// The entries of the first rename: the sender and its two documents.
		replica.cursor && { ...replica.cursor, sequenceNumber: replica.cursor.sequenceNumber + 3 },
		1,
	)
	const afterTheRenames = await follow(database, insuranceOnly, replica)

	expect({
		filled: upserts(filled),
		afterThePolicyLeft,
		insurerAlone: insurerAlone.kind === "page" && insurerAlone.page.changes,
		marketAlone: marketAlone.kind === "page" && marketAlone.page.changes,
		afterTheRenames: upserts(afterTheRenames),
	}).toEqual({
		filled: [
			"category Insurance",
			"document Allianz Liability Policy",
			"document Allianz Premium Statement 2026",
			"household_member Jonas Becker",
			"sender Allianz SE",
			"tag steuer",
			"tag tax-2026",
		],
		afterThePolicyLeft: ["removal document 50000000-0000-4000-8000-000000000001"],
		insurerAlone: [{ change: "upsert", record: { kind: "sender", id: insurer.id, name: "Allianz Versicherung SE" } }],
		marketAlone: [{ change: "removal", kind: "sender", id: market.id }],
		afterTheRenames: [
			"category Insurance",
			"document Allianz Premium Statement 2026",
			"sender Allianz Versicherung SE",
			"tag steuer",
			"tag tax-2026",
		],
	})
	expect(listedBy(replica)).toEqual(await listedByArchive(database, insuranceOnly))
})

test("a cursor of another journal or beyond the journal's end is refused, and malformed text is no cursor", async () => {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const database = connectDatabase(env.DATABASE)
	await database.insert(senders).values({ ...insurer, normalizedName: "allianz se" })
	const journalIdentifier = await readJournalIdentity(database)

	expect({
		parsed: parseJournalCursor("0123456789abcdef0123456789abcdef.42"),
		formatted: formatJournalCursor({ journalIdentifier: "0123456789abcdef0123456789abcdef", sequenceNumber: 42 }),
		malformed: [
			"",
			"0123456789abcdef0123456789abcdef",
			"0123456789ABCDEF0123456789ABCDEF.42",
			"0123456789abcdef0123456789abcdef.042",
			"0123456789abcdef0123456789abcdef.-1",
			"0123456789abcdef0123456789abcdef.42 ",
		].map(parseJournalCursor),
		identifierIsACursorPart: /^[0-9a-f]{32}$/.test(journalIdentifier),
		anotherJournal: await readJournalPage(database, wholeArchive, {
			journalIdentifier: "0123456789abcdef0123456789abcdef",
			sequenceNumber: 0,
		}),
		beyondTheEnd: await readJournalPage(database, wholeArchive, { journalIdentifier, sequenceNumber: 2 }),
		atTheEnd: await readJournalPage(database, wholeArchive, { journalIdentifier, sequenceNumber: 1 }),
	}).toEqual({
		parsed: { journalIdentifier: "0123456789abcdef0123456789abcdef", sequenceNumber: 42 },
		formatted: "0123456789abcdef0123456789abcdef.42",
		malformed: [undefined, undefined, undefined, undefined, undefined, undefined],
		identifierIsACursorPart: true,
		anotherJournal: { kind: "cursor_refused", reason: "another_journal" },
		beyondTheEnd: { kind: "cursor_refused", reason: "beyond_end" },
		atTheEnd: {
			kind: "page",
			page: { changes: [], nextCursor: { journalIdentifier, sequenceNumber: 1 }, remainingEntries: 0 },
		},
	})
})
