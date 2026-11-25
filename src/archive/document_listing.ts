import { and, asc, count, desc, eq, exists, gte, inArray, isNull, lte, ne, notExists, sql } from "drizzle-orm"
import {
	categories,
	documentTags,
	documents,
	extractedFields,
	householdMembers,
	senders,
	tags,
} from "../database/schema"
import { HOUSEHOLD_PERSON } from "../search/search_index_item"
import type { Column, SQL } from "drizzle-orm"
import type { AuthorizationScope } from "../authorization/caller_authorization"
import type { ArchiveDatabase } from "../database/client"
import type { DocumentFailureReason, DocumentStatus } from "../ingestion/document_lifecycle"
import type { SearchCriteria } from "../search/search_criteria"

interface ListedField {
	fieldKey: string
	value: string | number | null
	confidence: number | null
}

export interface ListedDocument {
	id: string
	status: DocumentStatus
	title: string | null
	documentDate: string | null
	senderName: string | null
	categoryName: string | null
	/** Null when the document concerns the whole household or is not yet classified. */
	personMemberId: string | null
	personName: string | null
	summary: string | null
	mimeType: string
	pageCount: number | null
	tagNames: Array<string>
	fields: Array<ListedField>
}

/**
 * Restricts a listing to the given documents and to every filter of the criteria. The query text
 * plays no part. A scope limits the listing to what an authorized client may read.
 */
export type ListingCriteria = Omit<SearchCriteria, "query"> & {
	documentIds?: Array<string>
	authorizationScope?: AuthorizationScope
}

/** One bound parameter however long the list is, because D1 allows 100 per query. */
function isListed(column: Column, identifiers: Array<string>): SQL {
	return sql`${column} IN (SELECT value FROM json_each(${JSON.stringify(identifiers)}))`
}

/**
 * Whether every tag of a JSON array of tag identifiers exists. A merge deletes the tag it folds
 * away and moves that tag's links to another tag in one batch. Asking in the statement that reads
 * the documents means no merge can slip in between and end the denial without anyone deciding
 * that, so such a scope admits nothing.
 */
export function everyTagExists(tagIdentifiers: SQL): SQL {
	return sql`(SELECT count(*) FROM ${tags} WHERE ${tags.id} IN (SELECT value FROM json_each(${tagIdentifiers}))) = (SELECT count(DISTINCT value) FROM json_each(${tagIdentifiers}))`
}

/**
 * Whether every tag the scope denies still exists. A scope whose denied tag was merged away admits
 * nothing, which scopeAdmission enforces inside each statement; a route asks this first to say so.
 */
export async function deniedTagsAllExist(database: ArchiveDatabase, deniedTags: Array<string> = []): Promise<boolean> {
	const distinctTagIds = [...new Set(deniedTags)]
	if (distinctTagIds.length === 0) return true
	return (await database.$count(tags, isListed(tags.id, distinctTagIds))) === distinctTagIds.length
}

/**
 * Whether a scope admits a row of documents, as a condition for any statement that reads that
 * table under its own name. It is the one definition: the listing, the facets, the tools of /mcp,
 * and the change journal all read through it. Only archived documents qualify, because a document
 * in ingestion holds its extracted text before classification assigns the category, sender, and
 * tags that a scope reads. A document must satisfy every list the scope holds. Without a scope
 * every document is admitted.
 */
export function scopeAdmission(database: ArchiveDatabase, scope: AuthorizationScope | undefined): SQL | undefined {
	if (scope === undefined) return undefined
	const linksToTags = (tagIds: Array<string>) =>
		database
			.select({ documentId: documentTags.documentId })
			.from(documentTags)
			.where(and(eq(documentTags.documentId, documents.id), isListed(documentTags.tagId, tagIds)))
	return and(
		eq(documents.status, "archived"),
		scope.allowedCategories === undefined ? undefined : isListed(documents.categoryId, scope.allowedCategories),
		scope.allowedSenders === undefined ? undefined : isListed(documents.senderId, scope.allowedSenders),
		scope.allowedTags === undefined ? undefined : exists(linksToTags(scope.allowedTags)),
		scope.deniedTags === undefined
			? undefined
			: and(everyTagExists(sql`${JSON.stringify(scope.deniedTags)}`), notExists(linksToTags(scope.deniedTags))),
	)
}

function listingConditions(database: ArchiveDatabase, criteria: ListingCriteria): Array<SQL | undefined> {
	const amountBounds = [
		criteria.minimumAmount === undefined ? undefined : gte(extractedFields.valueNumber, criteria.minimumAmount),
		criteria.maximumAmount === undefined ? undefined : lte(extractedFields.valueNumber, criteria.maximumAmount),
	]
	return [
		scopeAdmission(database, criteria.authorizationScope),
		criteria.documentIds === undefined ? undefined : inArray(documents.id, criteria.documentIds),
		// Classification assigns the person as it archives a document. An unclassified document
		// has none yet, so it belongs to no person, not even to the whole household.
		criteria.person === undefined
			? undefined
			: and(
					eq(documents.status, "archived"),
					criteria.person === HOUSEHOLD_PERSON
						? isNull(documents.personMemberId)
						: eq(documents.personMemberId, criteria.person),
				),
		criteria.sender === undefined ? undefined : eq(documents.senderId, criteria.sender),
		criteria.category === undefined ? undefined : eq(documents.categoryId, criteria.category),
		criteria.earliestDocumentDate === undefined
			? undefined
			: gte(documents.documentDate, criteria.earliestDocumentDate),
		criteria.latestDocumentDate === undefined ? undefined : lte(documents.documentDate, criteria.latestDocumentDate),
		criteria.tag === undefined
			? undefined
			: exists(
					database
						.select({ documentId: documentTags.documentId })
						.from(documentTags)
						.where(and(eq(documentTags.documentId, documents.id), eq(documentTags.tagId, criteria.tag))),
				),
		amountBounds.every((bound) => bound === undefined)
			? undefined
			: exists(
					database
						.select({ documentId: extractedFields.documentId })
						.from(extractedFields)
						.where(
							and(
								eq(extractedFields.documentId, documents.id),
								eq(extractedFields.fieldKey, "amount"),
								...amountBounds,
							),
						),
				),
	]
}

// A document still in ingestion has no date yet, so it stays on top. An archived document without a
// date takes the day it arrived.
const listingOrder = [
	desc(ne(documents.status, "archived")),
	desc(sql`coalesce(${documents.documentDate}, date(${documents.createdAt}, 'unixepoch'))`),
	desc(documents.createdAt),
	desc(documents.id),
]

/** A run of the listing in its order. */
export interface ListingPage {
	offset: number
	limit: number
}

/**
 * The statements of one listing, sent as one D1 batch. The fields and tags are read only for the
 * documents the listing holds, or for those on its page.
 */
function listingStatements(database: ArchiveDatabase, criteria: ListingCriteria, page?: ListingPage) {
	const conditions = and(...listingConditions(database, criteria))
	const listedIdentifiers = () => {
		const matching = database.select({ id: documents.id }).from(documents).where(conditions).$dynamic()
		return page === undefined
			? matching
			: matching
					.orderBy(...listingOrder)
					.limit(page.limit)
					.offset(page.offset)
	}
	const rows = database
		.select({
			id: documents.id,
			status: documents.status,
			title: documents.title,
			documentDate: documents.documentDate,
			// Drizzle reads a batch's rows by column name, so two columns named name would shift every later value.
			senderName: sql<string | null>`${senders.name}`.as("sender_name"),
			categoryName: sql<string | null>`${categories.name}`.as("category_name"),
			personMemberId: documents.personMemberId,
			personName: householdMembers.displayName,
			summary: documents.summary,
			mimeType: documents.mimeType,
			pageCount: documents.pageCount,
		})
		.from(documents)
		.leftJoin(senders, eq(documents.senderId, senders.id))
		.leftJoin(categories, eq(documents.categoryId, categories.id))
		.leftJoin(householdMembers, eq(documents.personMemberId, householdMembers.id))
		.where(conditions)
		.orderBy(...listingOrder)
		.$dynamic()
	return {
		total: database.select({ total: count() }).from(documents).where(conditions),
		rows: page === undefined ? rows : rows.limit(page.limit).offset(page.offset),
		fields: database
			.select({
				documentId: extractedFields.documentId,
				fieldKey: extractedFields.fieldKey,
				valueText: extractedFields.valueText,
				valueNumber: extractedFields.valueNumber,
				confidence: extractedFields.confidenceScore,
			})
			.from(extractedFields)
			.where(inArray(extractedFields.documentId, listedIdentifiers()))
			.orderBy(asc(extractedFields.fieldKey)),
		tags: database
			.select({ documentId: documentTags.documentId, name: tags.name })
			.from(documentTags)
			.innerJoin(tags, eq(documentTags.tagId, tags.id))
			.where(inArray(documentTags.documentId, listedIdentifiers()))
			.orderBy(asc(tags.name)),
	}
}

type ListingStatements = ReturnType<typeof listingStatements>

function groupByDocument<TRow extends { documentId: string }>(rows: Array<TRow>): Map<string, Array<TRow>> {
	const groups = new Map<string, Array<TRow>>()
	for (const row of rows) {
		const group = groups.get(row.documentId)
		if (group === undefined) groups.set(row.documentId, [row])
		else group.push(row)
	}
	return groups
}

function assembleListing(
	rows: Awaited<ListingStatements["rows"]>,
	fieldRows: Awaited<ListingStatements["fields"]>,
	tagRows: Awaited<ListingStatements["tags"]>,
): Array<ListedDocument> {
	const fieldsByDocument = groupByDocument(fieldRows)
	const tagsByDocument = groupByDocument(tagRows)
	return rows.map((row) => ({
		...row,
		tagNames: (tagsByDocument.get(row.id) ?? []).map((tag) => tag.name),
		fields: (fieldsByDocument.get(row.id) ?? []).map((field) => ({
			fieldKey: field.fieldKey,
			value: field.valueNumber ?? field.valueText,
			confidence: field.confidence,
		})),
	}))
}

export async function queryDocumentListing(
	database: ArchiveDatabase,
	criteria: ListingCriteria = {},
): Promise<Array<ListedDocument>> {
	const statements = listingStatements(database, criteria)
	const [rows, fieldRows, tagRows] = await database.batch([statements.rows, statements.fields, statements.tags])
	return assembleListing(rows, fieldRows, tagRows)
}

/** One page of the listing, with the number of documents the whole listing holds. */
export async function queryDocumentPage(
	database: ArchiveDatabase,
	criteria: ListingCriteria,
	page: ListingPage,
): Promise<{ totalDocuments: number; documents: Array<ListedDocument> }> {
	const statements = listingStatements(database, criteria, page)
	const [[total], rows, fieldRows, tagRows] = await database.batch([
		statements.total,
		statements.rows,
		statements.fields,
		statements.tags,
	])
	return { totalDocuments: total?.total ?? 0, documents: assembleListing(rows, fieldRows, tagRows) }
}

export interface DocumentStatusRecord {
	documentId: string
	title: string | null
	status: DocumentStatus
	failureReason: DocumentFailureReason | null
}

export async function queryDocumentStatuses(
	database: ArchiveDatabase,
	documentIds: Array<string>,
): Promise<Array<DocumentStatusRecord>> {
	return database
		.select({
			documentId: documents.id,
			title: documents.title,
			status: documents.status,
			failureReason: documents.failureReason,
		})
		.from(documents)
		.where(inArray(documents.id, documentIds))
}

export interface FacetOption {
	id: string
	name: string
	/** How many archived documents hold this value. */
	documentCount: number
}

/** The household members, senders, categories, and tags that the filter controls offer. */
export interface ArchiveFacets {
	members: Array<FacetOption>
	/** How many archived documents concern the whole household. */
	householdDocumentCount: number
	senders: Array<FacetOption>
	categories: Array<FacetOption & { expectedFields: Array<string> }>
	tags: Array<FacetOption>
}

/** Each count covers the archived documents that the scope admits, or all of them without a scope. */
export async function queryArchiveFacets(
	database: ArchiveDatabase,
	authorizationScope?: AuthorizationScope,
): Promise<ArchiveFacets> {
	const isArchived = and(eq(documents.status, "archived"), scopeAdmission(database, authorizationScope))
	const documentCount = count(documents.id)
	const [memberRows, [household], senderRows, categoryRows, tagRows] = await database.batch([
		database
			.select({ id: householdMembers.id, name: householdMembers.displayName, documentCount })
			.from(householdMembers)
			.leftJoin(documents, and(eq(documents.personMemberId, householdMembers.id), isArchived))
			.groupBy(householdMembers.id)
			.orderBy(asc(householdMembers.displayName)),
		database
			.select({ documentCount })
			.from(documents)
			.where(and(isArchived, isNull(documents.personMemberId))),
		database
			.select({ id: senders.id, name: senders.name, documentCount })
			.from(senders)
			.leftJoin(documents, and(eq(documents.senderId, senders.id), isArchived))
			.groupBy(senders.id)
			.orderBy(asc(senders.name)),
		database
			.select({
				id: categories.id,
				name: categories.name,
				expectedFields: categories.expectedFields,
				documentCount,
			})
			.from(categories)
			.leftJoin(documents, and(eq(documents.categoryId, categories.id), isArchived))
			.groupBy(categories.id)
			.orderBy(asc(categories.name)),
		database
			.select({ id: tags.id, name: tags.name, documentCount })
			.from(tags)
			.leftJoin(documentTags, eq(documentTags.tagId, tags.id))
			.leftJoin(documents, and(eq(documents.id, documentTags.documentId), isArchived))
			.groupBy(tags.id)
			.orderBy(asc(tags.name)),
	])
	return {
		members: memberRows,
		householdDocumentCount: household?.documentCount ?? 0,
		senders: senderRows,
		categories: categoryRows,
		tags: tagRows,
	}
}
