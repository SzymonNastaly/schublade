import { z } from "zod"
import { HOUSEHOLD_PERSON, documentIdOfItemName, searchIndexDateTime } from "./search_index_item"
import type { AuthorizationScope } from "../authorization/caller_authorization"

const MAXIMUM_QUERY_LENGTH = 500

/** The most documents one search returns. */
export const SEARCH_RESULT_LIMIT = 20

const PASSAGE_LENGTH = 240
const PASSAGE_LEADING_CONTEXT = 80

/** Parses search parameters from a URL or a server function call. An empty query lists documents. */
export const searchCriteriaSchema = z.strictObject({
	query: z.string().trim().max(MAXIMUM_QUERY_LENGTH).optional(),
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
 * The criteria of the archive page URL, read one parameter at a time. An unknown parameter,
 * such as utm_source, an unreadable one, such as minimumAmount=abc, and an empty one drop only
 * themselves.
 */
export function parseSearchParameters(parameters: Record<string, unknown>): SearchCriteria {
	const criteria: Record<string, unknown> = {}
	for (const [key, schema] of Object.entries(searchCriteriaSchema.shape)) {
		const field = schema.safeParse(parameters[key])
		if (parameters[key] !== "" && field.success && field.data !== undefined) criteria[key] = field.data
	}
	// Every field already parsed, so this parse only gives the result its type.
	return searchCriteriaSchema.parse(criteria)
}

/**
 * Reads a URL search string. Each value is text, whereas the router default parses each value
 * as JSON and turns a query such as 1.50 or 1e3 into a number. The router keeps only what this
 * returns.
 */
export function parseSearchString(searchString: string): SearchCriteria {
	return parseSearchParameters(Object.fromEntries(new URLSearchParams(searchString)))
}

/** Writes each defined value as text, so parseSearchString reads it back unchanged. */
export function composeSearchString(search: Record<string, unknown>): string {
	const parameters = new URLSearchParams()
	for (const [key, value] of Object.entries(search)) {
		if (value !== undefined) parameters.set(key, String(value))
	}
	const searchString = parameters.toString()
	return searchString === "" ? "" : `?${searchString}`
}

/** A chosen value, or else the values a scope allows. D1 rejects a chosen value outside the scope afterwards. */
function metadataRestriction(chosen: string | undefined, allowed: Array<string> | undefined) {
	return chosen ?? (allowed === undefined ? undefined : { $in: allowed })
}

/**
 * The criteria AI Search applies before it ranks, so the top results come from the filtered
 * set. Each metadata field holds one value, so tags cannot be filtered here, and amounts live
 * in extracted_fields.
 */
export function searchIndexFilter(
	criteria: SearchCriteria & { authorizationScope?: AuthorizationScope },
): VectorizeVectorMetadataFilter | undefined {
	const sender = metadataRestriction(criteria.sender, criteria.authorizationScope?.allowedSenders)
	const category = metadataRestriction(criteria.category, criteria.authorizationScope?.allowedCategories)
	const documentDateRange = {
		...(criteria.earliestDocumentDate !== undefined && { $gte: searchIndexDateTime(criteria.earliestDocumentDate) }),
		...(criteria.latestDocumentDate !== undefined && { $lte: searchIndexDateTime(criteria.latestDocumentDate) }),
	}
	const filter: VectorizeVectorMetadataFilter = {
		...(criteria.person !== undefined && { person: criteria.person }),
		...(sender !== undefined && { sender }),
		...(category !== undefined && { category }),
		...(Object.keys(documentDateRange).length > 0 && { document_date: documentDateRange }),
	}
	return Object.keys(filter).length > 0 ? filter : undefined
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
