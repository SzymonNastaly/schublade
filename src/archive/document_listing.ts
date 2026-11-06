import { and, asc, desc, eq, exists, gte, inArray, isNull, lte } from "drizzle-orm"
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
import type { SQL } from "drizzle-orm"
import type { ArchiveDatabase } from "../database/client"
import type { DocumentStatus } from "../ingestion/document_lifecycle"
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
	personName: string | null
	summary: string | null
	mimeType: string
	pageCount: number | null
	verificationReason: VerificationReason | null
	fields: Array<ListedField>
}

/** Restricts a listing to the given documents and to every filter of the criteria. The query text plays no part. */
export type ListingCriteria = Omit<SearchCriteria, "query"> & { documentIds?: Array<string> }

function listingConditions(database: ArchiveDatabase, criteria: ListingCriteria): Array<SQL | undefined> {
	const amountBounds = [
		criteria.minimumAmount === undefined ? undefined : gte(extractedFields.valueNumber, criteria.minimumAmount),
		criteria.maximumAmount === undefined ? undefined : lte(extractedFields.valueNumber, criteria.maximumAmount),
	]
	return [
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

export async function queryDocumentListing(
	database: ArchiveDatabase,
	criteria: ListingCriteria = {},
): Promise<Array<ListedDocument>> {
	const [rows, fieldRows] = await Promise.all([
		database
			.select({
				id: documents.id,
				status: documents.status,
				title: documents.title,
				documentDate: documents.documentDate,
				senderName: senders.name,
				categoryName: categories.name,
				personName: householdMembers.displayName,
				summary: documents.summary,
				mimeType: documents.mimeType,
				pageCount: documents.pageCount,
				verificationReason: documents.verificationReason,
			})
			.from(documents)
			.leftJoin(senders, eq(documents.senderId, senders.id))
			.leftJoin(categories, eq(documents.categoryId, categories.id))
			.leftJoin(householdMembers, eq(documents.personMemberId, householdMembers.id))
			.where(and(...listingConditions(database, criteria)))
			.orderBy(desc(documents.createdAt), desc(documents.id)),
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
	return rows.map((row) => ({ ...row, fields: fieldsByDocument.get(row.id) ?? [] }))
}

interface FacetOption {
	id: string
	name: string
}

/** The household members, senders, categories, and tags that the filter controls offer. */
export interface ArchiveFacets {
	members: Array<FacetOption>
	senders: Array<FacetOption>
	categories: Array<FacetOption>
	tags: Array<FacetOption>
}

export async function queryArchiveFacets(database: ArchiveDatabase): Promise<ArchiveFacets> {
	const [memberRows, senderRows, categoryRows, tagRows] = await Promise.all([
		database
			.select({ id: householdMembers.id, name: householdMembers.displayName })
			.from(householdMembers)
			.orderBy(asc(householdMembers.displayName)),
		database.select({ id: senders.id, name: senders.name }).from(senders).orderBy(asc(senders.name)),
		database.select({ id: categories.id, name: categories.name }).from(categories).orderBy(asc(categories.name)),
		database.select({ id: tags.id, name: tags.name }).from(tags).orderBy(asc(tags.name)),
	])
	return { members: memberRows, senders: senderRows, categories: categoryRows, tags: tagRows }
}
