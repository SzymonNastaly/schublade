import { z } from "zod"
import { HOUSEHOLD_PERSON, documentIdOfItemName, searchIndexDateTime } from "./search_index_item"

const MAXIMUM_QUERY_LENGTH = 500

/** The most documents one search returns. */
export const SEARCH_RESULT_LIMIT = 20

// AI Search returns at most 50 chunks per query.
const MAXIMUM_CANDIDATE_CHUNKS = 50

const PASSAGE_LENGTH = 240
const PASSAGE_LEADING_CONTEXT = 80

/** Parses search parameters from a URL or a server function call. An empty query lists documents. */
export const searchCriteriaSchema = z.strictObject({
	// The router parses a numeric query, such as an invoice number, into a number.
	query: z.coerce.string().trim().max(MAXIMUM_QUERY_LENGTH).optional(),
	person: z.union([z.uuid(), z.literal(HOUSEHOLD_PERSON)]).optional(),
	sender: z.uuid().optional(),
	category: z.uuid().optional(),
	tag: z.uuid().optional(),
	earliestDocumentDate: z.iso.date().optional(),
	latestDocumentDate: z.iso.date().optional(),
	minimumAmount: z.coerce.number().nonnegative().optional(),
	maximumAmount: z.coerce.number().nonnegative().optional(),
})

export type SearchCriteria = z.infer<typeof searchCriteriaSchema>

/**
 * The criteria AI Search applies before it ranks, so the top results come from the filtered
 * set. Each metadata field holds one value, so tags cannot be filtered here, and amounts live
 * in extracted_fields.
 */
export function searchIndexFilter(criteria: SearchCriteria): VectorizeVectorMetadataFilter | undefined {
	const documentDateRange = {
		...(criteria.earliestDocumentDate !== undefined && { $gte: searchIndexDateTime(criteria.earliestDocumentDate) }),
		...(criteria.latestDocumentDate !== undefined && { $lte: searchIndexDateTime(criteria.latestDocumentDate) }),
	}
	const filter: VectorizeVectorMetadataFilter = {
		...(criteria.person !== undefined && { person: criteria.person }),
		...(criteria.sender !== undefined && { sender: criteria.sender }),
		...(criteria.category !== undefined && { category: criteria.category }),
		...(Object.keys(documentDateRange).length > 0 && { document_date: documentDateRange }),
	}
	return Object.keys(filter).length > 0 ? filter : undefined
}

/** True when D1 removes candidates that AI Search already ranked: a tag or an amount bound. */
function hasDatabaseOnlyCriteria(criteria: SearchCriteria): boolean {
	return criteria.tag !== undefined || criteria.minimumAmount !== undefined || criteria.maximumAmount !== undefined
}

/**
 * The number of chunks to request from AI Search. When D1 discards candidates afterwards, the
 * search requests as many as AI Search returns, so the page still fills.
 */
export function candidateChunkCount(criteria: SearchCriteria): number {
	return hasDatabaseOnlyCriteria(criteria) ? MAXIMUM_CANDIDATE_CHUNKS : SEARCH_RESULT_LIMIT
}

/**
 * The part of a chunk around the whole query, or else around its longest term, or the
 * beginning of the chunk when it matched by meaning alone. A short term such as "31" in an
 * IBAN also occurs in postal codes, so longer terms locate the match first.
 */
function excerptPassage(chunkText: string, query: string): string {
	const text = chunkText
		.replace(/^#+\s*/gm, "")
		.replace(/\s+/g, " ")
		.trim()
	const lowerText = text.toLowerCase()
	const lowerQuery = query.toLowerCase().replace(/\s+/g, " ")
	const terms = lowerQuery.split(" ").sort((first, second) => second.length - first.length)
	const matchPosition =
		[lowerQuery, ...terms]
			.filter((term) => term.length >= 2)
			.map((term) => lowerText.indexOf(term))
			.find((position) => position >= 0) ?? 0
	const precedingSpace = text.lastIndexOf(" ", Math.max(0, matchPosition - PASSAGE_LEADING_CONTEXT))
	const start = matchPosition <= PASSAGE_LEADING_CONTEXT || precedingSpace < 0 ? 0 : precedingSpace + 1
	const followingSpace = text.indexOf(" ", start + PASSAGE_LENGTH)
	const end = followingSpace < 0 ? text.length : followingSpace
	return `${start > 0 ? "…" : ""}${text.slice(start, end)}${end < text.length ? "…" : ""}`
}

export interface RankedPassage {
	documentId: string
	passage: string
}

/** One passage per document, from its best chunk, in the order AI Search ranked them. */
export function rankPassages(chunks: AiSearchSearchResponse["chunks"], query: string): Array<RankedPassage> {
	const passages = new Map<string, string>()
	for (const chunk of [...chunks].sort((first, second) => second.score - first.score)) {
		const documentId = documentIdOfItemName(chunk.item.key)
		if (documentId !== undefined && !passages.has(documentId)) {
			passages.set(documentId, excerptPassage(chunk.text, query))
		}
	}
	return [...passages].map(([documentId, passage]) => ({ documentId, passage }))
}
