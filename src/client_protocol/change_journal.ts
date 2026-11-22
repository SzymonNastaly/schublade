import { and, asc, eq, gt, inArray, sql } from "drizzle-orm"
import { scopeAdmission } from "../archive/document_listing"
import { isRestrictedScope } from "../authorization/caller_authorization"
import {
	categories,
	changeJournal,
	changeJournalIdentity,
	documentTags,
	documents,
	extractedFields,
	householdMembers,
	senders,
	tags,
} from "../database/schema"
import type { SQL } from "drizzle-orm"
import type { AuthorizationScope } from "../authorization/caller_authorization"
import type { ArchiveDatabase } from "../database/client"
import type { JournaledRecordKind } from "../database/schema"
import type { DocumentFailureReason, DocumentStatus } from "../ingestion/document_lifecycle"

/** The most journal entries one page covers. A client cannot ask for more. */
const JOURNAL_PAGE_SIZE = 250

/**
 * A position in one journal: its holder has the state of every record whose entry has this number
 * or a smaller one, as of a moment at or after that entry.
 */
export interface JournalCursor {
	journalIdentifier: string
	sequenceNumber: number
}

// 15 digits keep the number below 2^53, so it is exact.
const cursorPattern = /^([0-9a-f]{32})\.(0|[1-9][0-9]{0,14})$/

/** Undefined for text that is no cursor. */
export function parseJournalCursor(text: string): JournalCursor | undefined {
	const [, journalIdentifier, sequenceNumber] = cursorPattern.exec(text) ?? []
	if (journalIdentifier === undefined) return undefined
	return { journalIdentifier, sequenceNumber: Number(sequenceNumber) }
}

export function formatJournalCursor(cursor: JournalCursor): string {
	return `${cursor.journalIdentifier}.${cursor.sequenceNumber}`
}

/**
 * Whom a document concerns. Classification assigns the person as it archives a document, so a
 * document that is not archived concerns nobody yet, not even the whole household.
 */
type DocumentPerson = { kind: "unassigned" } | { kind: "household" } | { kind: "member"; memberId: string }

type ExtractedFieldRecord = { fieldKey: string; confidenceScore: number | null } & (
	| { fieldType: "number"; value: number }
	/** A date is ISO 8601 text. */
	| { fieldType: "text" | "date"; value: string }
)

/** A document as a client copies it: whole, with its tags and its extracted fields. */
interface DocumentRecord {
	id: string
	status: DocumentStatus
	failureReason: DocumentFailureReason | null
	title: string | null
	documentDate: string | null
	senderId: string | null
	categoryId: string | null
	person: DocumentPerson
	summary: string | null
	mimeType: string
	byteSize: number
	originalSha256: string | null
	pageCount: number | null
	tagIds: Array<string>
	fields: Array<ExtractedFieldRecord>
	createdAt: Date
	updatedAt: Date
}

interface HouseholdMemberRecord {
	id: string
	displayName: string
}

interface SenderRecord {
	id: string
	name: string
}

interface CategoryRecord {
	id: string
	name: string
	expectedFields: Array<string>
}

interface TagRecord {
	id: string
	name: string
	colorHex: string | null
}

export type JournaledRecord =
	| ({ kind: "document" } & DocumentRecord)
	| ({ kind: "household_member" } & HouseholdMemberRecord)
	| ({ kind: "sender" } & SenderRecord)
	| ({ kind: "category" } & CategoryRecord)
	| ({ kind: "tag" } & TagRecord)

/**
 * An upsert carries the record as it is now and replaces whatever the client holds of it. A
 * removal names a record that no longer exists or that the scope does not admit, whether or not
 * the client ever held it.
 */
export type RecordChange =
	{ change: "upsert"; record: JournaledRecord } | { change: "removal"; kind: JournaledRecordKind; id: string }

interface JournalPage {
	/**
	 * Each record at most once. The household members, senders, categories, and tags come first,
	 * then the documents in journal order, then the removals, so a client that applies the changes
	 * in this order never holds a document whose reference it cannot resolve.
	 */
	changes: Array<RecordChange>
	/** What the client sends to read the page after this one. */
	nextCursor: JournalCursor
	/**
	 * The entries after this page when it was read, removals and records the scope hides included,
	 * so it bounds what the following pages hold.
	 */
	remainingEntries: number
}

export type JournalPageOutcome =
	| { kind: "page"; page: JournalPage }
	/**
	 * The cursor names another journal than this database keeps, or a number this journal has not
	 * issued, as after a restore. Its client discards its copy and reads from the start.
	 */
	| { kind: "cursor_refused"; reason: "another_journal" | "beyond_end" }

export async function readJournalIdentity(database: ArchiveDatabase): Promise<string> {
	const [identity] = await database
		.select({ journalIdentifier: changeJournalIdentity.journalIdentifier })
		.from(changeJournalIdentity)
	if (!identity) throw new Error("change_journal_identity holds no row, which migration 0009 writes")
	return identity.journalIdentifier
}

/**
 * Reads the entries after the cursor, or from the journal's start without one, with the present
 * state of their records. The whole read is one D1 batch, which is one transaction, so the page
 * is one snapshot: a write that commits later has a number above every entry of the page, and a
 * later page delivers it. If the Worker ever reads through the D1 Sessions API, this read must
 * use the primary, or a replica could answer with a snapshot older than the cursor.
 *
 * A document the scope does not admit is a removal. The page also carries every household
 * member, sender, category, and tag that one of its admitted documents refers to, so each
 * reference resolves once the page is applied. Such a record of the page itself is sent to a
 * restricted scope only while the scope admits a document, anywhere in the archive, that refers
 * to it, and is a removal otherwise. That is enough, because every write that makes a document
 * refer to a record, or admits a document, moves the entry of that document.
 */
export async function readJournalPage(
	database: ArchiveDatabase,
	scope: AuthorizationScope,
	cursor: JournalCursor | undefined,
	entryLimit = JOURNAL_PAGE_SIZE,
): Promise<JournalPageOutcome> {
	// A scope without lists reads documents in ingestion too, which a client shows as arriving.
	const admission = scopeAdmission(database, isRestrictedScope(scope) ? scope : undefined)
	const page = database.$with("page").as(
		database
			.select()
			.from(changeJournal)
			.where(gt(changeJournal.sequenceNumber, cursor?.sequenceNumber ?? 0))
			.orderBy(asc(changeJournal.sequenceNumber))
			.limit(entryLimit),
	)
	const admittedDocuments = database.$with("admitted_documents").as(
		database
			.select({
				id: documents.id,
				senderId: documents.senderId,
				categoryId: documents.categoryId,
				personMemberId: documents.personMemberId,
			})
			.from(page)
			// Without statistics, SQLite's planner starts from documents_status_index and reads every
			// archived document to find those of the page. A cross join keeps the page first.
			.crossJoin(documents)
			.where(and(eq(page.recordKind, "document"), eq(documents.id, page.recordIdentifier), admission)),
	)
	const snapshot = database.with(page, admittedDocuments)
	const admittedDocumentIds = sql`(SELECT ${admittedDocuments.id} FROM ${admittedDocuments})`
	// One subquery, so the statement looks each identifier up by its primary key. The documents
	// that refer to a record are read through a named index, for the reason the cross join has.
	const identifiersToSend = (kind: JournaledRecordKind, referenced: SQL, referringDocuments: SQL): SQL => {
		const admittedSomewhere =
			admission === undefined ? sql`` : sql` AND EXISTS (SELECT 1 FROM ${referringDocuments} AND ${admission})`
		return sql`(${referenced} UNION SELECT ${page.recordIdentifier} FROM ${page} WHERE ${page.recordKind} = ${kind}${admittedSomewhere})`
	}

	const [[identity], entries, documentRows, tagLinks, fieldRows, memberRows, senderRows, categoryRows, tagRows] =
		await database.batch([
			snapshot
				.select({
					journalIdentifier: changeJournalIdentity.journalIdentifier,
					lastSequenceNumber: sql<number>`(SELECT coalesce(max(${changeJournal.sequenceNumber}), 0) FROM ${changeJournal})`,
					// A count over the primary key's range after the page's last entry, for a client's progress.
					remainingEntries: sql<number>`(SELECT count(*) FROM ${changeJournal} WHERE ${changeJournal.sequenceNumber} > coalesce((SELECT max(${page.sequenceNumber}) FROM ${page}), ${cursor?.sequenceNumber ?? 0}))`,
				})
				.from(changeJournalIdentity),
			snapshot.select().from(page).orderBy(asc(page.sequenceNumber)),
			snapshot
				.select({
					id: documents.id,
					status: documents.status,
					failureReason: documents.failureReason,
					title: documents.title,
					documentDate: documents.documentDate,
					senderId: documents.senderId,
					categoryId: documents.categoryId,
					personMemberId: documents.personMemberId,
					summary: documents.summary,
					mimeType: documents.mimeType,
					byteSize: documents.byteSize,
					originalSha256: documents.originalSha256,
					pageCount: documents.pageCount,
					createdAt: documents.createdAt,
					updatedAt: documents.updatedAt,
				})
				.from(documents)
				.where(inArray(documents.id, admittedDocumentIds)),
			snapshot
				.select()
				.from(documentTags)
				.where(inArray(documentTags.documentId, admittedDocumentIds))
				.orderBy(asc(documentTags.tagId)),
			snapshot
				.select()
				.from(extractedFields)
				.where(inArray(extractedFields.documentId, admittedDocumentIds))
				.orderBy(asc(extractedFields.fieldKey)),
			snapshot
				.select({ id: householdMembers.id, displayName: householdMembers.displayName })
				.from(householdMembers)
				.where(
					inArray(
						householdMembers.id,
						identifiersToSend(
							"household_member",
							sql`SELECT ${admittedDocuments.personMemberId} FROM ${admittedDocuments}`,
							sql`${documents} INDEXED BY documents_person_member_id_index WHERE ${documents.personMemberId} = ${page.recordIdentifier}`,
						),
					),
				)
				.orderBy(asc(householdMembers.id)),
			snapshot
				.select({ id: senders.id, name: senders.name })
				.from(senders)
				.where(
					inArray(
						senders.id,
						identifiersToSend(
							"sender",
							sql`SELECT ${admittedDocuments.senderId} FROM ${admittedDocuments}`,
							sql`${documents} INDEXED BY documents_sender_id_index WHERE ${documents.senderId} = ${page.recordIdentifier}`,
						),
					),
				)
				.orderBy(asc(senders.id)),
			snapshot
				.select({ id: categories.id, name: categories.name, expectedFields: categories.expectedFields })
				.from(categories)
				.where(
					inArray(
						categories.id,
						identifiersToSend(
							"category",
							sql`SELECT ${admittedDocuments.categoryId} FROM ${admittedDocuments}`,
							sql`${documents} INDEXED BY documents_category_id_index WHERE ${documents.categoryId} = ${page.recordIdentifier}`,
						),
					),
				)
				.orderBy(asc(categories.id)),
			snapshot
				.select({ id: tags.id, name: tags.name, colorHex: tags.colorHex })
				.from(tags)
				.where(
					inArray(
						tags.id,
						identifiersToSend(
							"tag",
							sql`SELECT ${documentTags.tagId} FROM ${documentTags} WHERE ${documentTags.documentId} IN ${admittedDocumentIds}`,
							sql`${documentTags} INDEXED BY document_tags_tag_id_index CROSS JOIN ${documents} WHERE ${documentTags.tagId} = ${page.recordIdentifier} AND ${documents.id} = ${documentTags.documentId}`,
						),
					),
				)
				.orderBy(asc(tags.id)),
		])
	if (!identity) throw new Error("change_journal_identity holds no row, which migration 0009 writes")
	if (cursor !== undefined) {
		if (cursor.journalIdentifier !== identity.journalIdentifier) {
			return { kind: "cursor_refused", reason: "another_journal" }
		}
		if (cursor.sequenceNumber > identity.lastSequenceNumber) return { kind: "cursor_refused", reason: "beyond_end" }
	}

	const admittedDocumentRecords = new Map(
		documentRows.map(({ personMemberId, ...document }): [string, JournaledRecord] => [
			document.id,
			{
				kind: "document",
				...document,
				person:
					personMemberId !== null
						? { kind: "member", memberId: personMemberId }
						: { kind: document.status === "archived" ? "household" : "unassigned" },
				tagIds: tagLinks.filter((link) => link.documentId === document.id).map((link) => link.tagId),
				fields: fieldRows
					.filter((field) => field.documentId === document.id)
					.flatMap(({ fieldKey, fieldType, valueText, valueNumber, confidenceScore }): Array<ExtractedFieldRecord> => {
						if (fieldType === "number") {
							return valueNumber === null ? [] : [{ fieldKey, fieldType, value: valueNumber, confidenceScore }]
						}
						return valueText === null ? [] : [{ fieldKey, fieldType, value: valueText, confidenceScore }]
					}),
			},
		]),
	)
	const records: Array<JournaledRecord> = [
		...memberRows.map((member) => ({ kind: "household_member" as const, ...member })),
		...senderRows.map((sender) => ({ kind: "sender" as const, ...sender })),
		...categoryRows.map((category) => ({ kind: "category" as const, ...category })),
		...tagRows.map((tag) => ({ kind: "tag" as const, ...tag })),
		...entries.flatMap((entry) => {
			const document = entry.recordKind === "document" ? admittedDocumentRecords.get(entry.recordIdentifier) : undefined
			return document === undefined ? [] : [document]
		}),
	]
	const sent = new Set(records.map((record) => `${record.kind} ${record.id}`))
	const lastSequenceNumber = entries.at(-1)?.sequenceNumber ?? cursor?.sequenceNumber ?? 0
	return {
		kind: "page",
		page: {
			changes: [
				...records.map((record): RecordChange => ({ change: "upsert", record })),
				...entries
					.filter((entry) => !sent.has(`${entry.recordKind} ${entry.recordIdentifier}`))
					.map((entry): RecordChange => ({ change: "removal", kind: entry.recordKind, id: entry.recordIdentifier })),
			],
			nextCursor: { journalIdentifier: identity.journalIdentifier, sequenceNumber: lastSequenceNumber },
			remainingEntries: identity.remainingEntries,
		},
	}
}
