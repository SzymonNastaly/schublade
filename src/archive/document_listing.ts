import {
	and,
	asc,
	count,
	desc,
	eq,
	exists,
	gte,
	inArray,
	isNotNull,
	isNull,
	lte,
	notExists,
	or,
	sql,
} from "drizzle-orm"
import {
	categories,
	documentTags,
	documents,
	extractedFields,
	householdMembers,
	senders,
	tags,
} from "../database/schema"
import { effectiveVerificationReason } from "../ingestion/verification_assessment"
import { HOUSEHOLD_PERSON } from "../search/search_index_item"
import type { Column, SQL } from "drizzle-orm"
import type { AuthorizationScope } from "../authorization/caller_authorization"
import type { ArchiveDatabase } from "../database/client"
import type { DocumentFailureReason, DocumentStatus } from "../ingestion/document_lifecycle"
import type { VerificationReason } from "../ingestion/verification_assessment"
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
	verificationReason: VerificationReason | null
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
 * A merge deletes the tag it folds away and moves that tag's links to another tag in one batch.
 * Asking in the statement that reads the documents means no merge can slip in between and end the
 * denial without anyone deciding that, so such a scope admits nothing.
 */
function everyTagExists(tagIds: Array<string>): SQL {
	const distinctTagIds = [...new Set(tagIds)]
	return sql`(SELECT count(*) FROM ${tags} WHERE ${isListed(tags.id, distinctTagIds)}) = ${distinctTagIds.length}`
}

/**
 * The documents a scope admits. Only archived documents qualify, because a document in ingestion
 * holds its extracted text before classification assigns the category, sender, and tags that a
 * scope reads. A document must satisfy every list the scope holds.
 */
function authorizationScopeConditions(
	database: ArchiveDatabase,
	scope: AuthorizationScope | undefined,
): Array<SQL | undefined> {
	if (scope === undefined) return []
	const linksToTags = (tagIds: Array<string>) =>
		database
			.select({ documentId: documentTags.documentId })
			.from(documentTags)
			.where(and(eq(documentTags.documentId, documents.id), isListed(documentTags.tagId, tagIds)))
	return [
		eq(documents.status, "archived"),
		scope.allowedCategories === undefined ? undefined : isListed(documents.categoryId, scope.allowedCategories),
		scope.allowedSenders === undefined ? undefined : isListed(documents.senderId, scope.allowedSenders),
		scope.allowedTags === undefined ? undefined : exists(linksToTags(scope.allowedTags)),
		scope.deniedTags === undefined
			? undefined
			: and(everyTagExists(scope.deniedTags), notExists(linksToTags(scope.deniedTags))),
	]
}

function listingConditions(database: ArchiveDatabase, criteria: ListingCriteria): Array<SQL | undefined> {
	const amountBounds = [
		criteria.minimumAmount === undefined ? undefined : gte(extractedFields.valueNumber, criteria.minimumAmount),
		criteria.maximumAmount === undefined ? undefined : lte(extractedFields.valueNumber, criteria.maximumAmount),
	]
	return [
		...authorizationScopeConditions(database, criteria.authorizationScope),
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

/** True for a document whose sender, category, or a tag awaits confirmation. Joins senders and categories. */
function refersToUnconfirmedRecord(database: ArchiveDatabase) {
	const condition = or(
		and(isNotNull(senders.id), isNull(senders.confirmedAt)),
		and(isNotNull(categories.id), isNull(categories.confirmedAt)),
		exists(
			database
				.select({ tagId: documentTags.tagId })
				.from(documentTags)
				.innerJoin(tags, eq(documentTags.tagId, tags.id))
				.where(and(eq(documentTags.documentId, documents.id), isNull(tags.confirmedAt))),
		),
	)
	return sql<boolean>`${condition}`.mapWith(Boolean)
}

export async function queryDocumentListing(
	database: ArchiveDatabase,
	criteria: ListingCriteria = {},
): Promise<Array<ListedDocument>> {
	const [rows, fieldRows, tagRows] = await Promise.all([
		database
			.select({
				id: documents.id,
				status: documents.status,
				title: documents.title,
				documentDate: documents.documentDate,
				senderName: senders.name,
				categoryName: categories.name,
				personMemberId: documents.personMemberId,
				personName: householdMembers.displayName,
				summary: documents.summary,
				mimeType: documents.mimeType,
				pageCount: documents.pageCount,
				storedVerificationReason: documents.verificationReason,
				refersToUnconfirmedRecord: refersToUnconfirmedRecord(database),
			})
			.from(documents)
			.leftJoin(senders, eq(documents.senderId, senders.id))
			.leftJoin(categories, eq(documents.categoryId, categories.id))
			.leftJoin(householdMembers, eq(documents.personMemberId, householdMembers.id))
			.where(and(...listingConditions(database, criteria)))
			// A document without a date is still in processing or needs one supplied, so it stays on top.
			.orderBy(
				desc(isNull(documents.documentDate)),
				desc(documents.documentDate),
				desc(documents.createdAt),
				desc(documents.id),
			),
		database
			.select({
				documentId: extractedFields.documentId,
				fieldKey: extractedFields.fieldKey,
				valueText: extractedFields.valueText,
				valueNumber: extractedFields.valueNumber,
				confidence: extractedFields.confidenceScore,
			})
			.from(extractedFields)
			.where(criteria.documentIds === undefined ? undefined : inArray(extractedFields.documentId, criteria.documentIds))
			.orderBy(asc(extractedFields.fieldKey)),
		database
			.select({ documentId: documentTags.documentId, name: tags.name })
			.from(documentTags)
			.innerJoin(tags, eq(documentTags.tagId, tags.id))
			.where(criteria.documentIds === undefined ? undefined : inArray(documentTags.documentId, criteria.documentIds))
			.orderBy(asc(tags.name)),
	])
	const fieldsByDocument = new Map<string, Array<ListedField>>()
	for (const field of fieldRows) {
		const listedFields = fieldsByDocument.get(field.documentId) ?? []
		listedFields.push({
			fieldKey: field.fieldKey,
			value: field.valueNumber ?? field.valueText,
			confidence: field.confidence,
		})
		fieldsByDocument.set(field.documentId, listedFields)
	}
	return rows.map(({ storedVerificationReason, refersToUnconfirmedRecord: unconfirmed, ...row }) => ({
		...row,
		verificationReason: effectiveVerificationReason(storedVerificationReason, unconfirmed),
		tagNames: tagRows.filter((tag) => tag.documentId === row.id).map((tag) => tag.name),
		fields: fieldsByDocument.get(row.id) ?? [],
	}))
}

export interface DocumentStatusRecord {
	documentId: string
	title: string | null
	status: DocumentStatus
	failureReason: DocumentFailureReason | null
	needsReview: boolean
}

export async function queryDocumentStatuses(
	database: ArchiveDatabase,
	documentIds: Array<string>,
): Promise<Array<DocumentStatusRecord>> {
	const rows = await database
		.select({
			documentId: documents.id,
			title: documents.title,
			status: documents.status,
			failureReason: documents.failureReason,
			storedVerificationReason: documents.verificationReason,
			refersToUnconfirmedRecord: refersToUnconfirmedRecord(database),
		})
		.from(documents)
		.leftJoin(senders, eq(documents.senderId, senders.id))
		.leftJoin(categories, eq(documents.categoryId, categories.id))
		.where(inArray(documents.id, documentIds))
	return rows.map(({ storedVerificationReason, refersToUnconfirmedRecord: unconfirmed, ...row }) => ({
		...row,
		needsReview: effectiveVerificationReason(storedVerificationReason, unconfirmed) !== null,
	}))
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
	const isArchived = and(
		eq(documents.status, "archived"),
		...authorizationScopeConditions(database, authorizationScope),
	)
	const documentCount = count(documents.id)
	const [memberRows, householdDocumentCount, senderRows, categoryRows, tagRows] = await Promise.all([
		database
			.select({ id: householdMembers.id, name: householdMembers.displayName, documentCount })
			.from(householdMembers)
			.leftJoin(documents, and(eq(documents.personMemberId, householdMembers.id), isArchived))
			.groupBy(householdMembers.id)
			.orderBy(asc(householdMembers.displayName)),
		database.$count(documents, and(isArchived, isNull(documents.personMemberId))),
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
		householdDocumentCount,
		senders: senderRows,
		categories: categoryRows,
		tags: tagRows,
	}
}
