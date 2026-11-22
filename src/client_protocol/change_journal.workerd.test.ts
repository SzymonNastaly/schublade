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
		if (!outcome.page.moreFollow) return received
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

test("every table is journaled or listed as not replicated, and every journaled table has its three triggers", async () => {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))

	const { results: tables } = await env.DATABASE.prepare(
		"SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> 'd1_migrations'",
	).all<{ name: string }>()
	const { results: triggers } = await env.DATABASE.prepare(
		"SELECT tbl_name, sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name",
	).all<{ tbl_name: string; sql: string }>()
	const eventsByTable: Record<string, Array<string>> = {}
	for (const trigger of triggers) {
		// A trigger with a column list, AFTER UPDATE OF, counts for nothing: it would miss the other columns.
		const [, event] = /AFTER (INSERT|UPDATE|DELETE) ON/.exec(trigger.sql) ?? []
		if (event !== undefined) (eventsByTable[trigger.tbl_name] ??= []).push(event)
	}

	expect({ tables: tables.map((table) => table.name).sort(), eventsByTable }).toEqual({
		tables: [...Object.keys(journaledTables), ...tablesNotReplicated].sort(),
		eventsByTable: Object.fromEntries(
			Object.keys(journaledTables)
				.sort()
				.map((table) => [table, ["DELETE", "INSERT", "UPDATE"]]),
		),
	})
})

test("a client that pages from any earlier cursor ends with the state the listing reports", async () => {
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
					model === "@cf/moondream/moondream3.1-9B-A2B"
						? new Response(recording.textRecognitionEventStream).body
						: recording.classificationResponse,
				),
		} as unknown as Ai,
		CLASSIFICATION_MODEL: "@cf/deepseek-ai/deepseek-v4.1-flash-1017",
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
		expect(listedBy(current)).toEqual(await listedByArchive(database))
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
			"Stadtwerke Talbrück Invoice Electricity Consumption September 2025 to August 2026",
		],
	})
	expect(repeatedPages[0]).toEqual(repeatedPages[1])
	for (const replica of replicas) expect(listedBy(replica)).toEqual(listing)
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
			page: { changes: [], nextCursor: { journalIdentifier, sequenceNumber: 1 }, moreFollow: false },
		},
	})
})
