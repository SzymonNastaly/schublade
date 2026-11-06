import { queryDocumentListing } from "../archive/document_listing"
import { SEARCH_RESULT_LIMIT, candidateChunkCount, rankPassages, searchIndexFilter } from "./search_criteria"
import type { ListedDocument } from "../archive/document_listing"
import type { ArchiveDatabase } from "../database/client"
import type { SearchIndex } from "./document_indexing"
import type { SearchCriteria } from "./search_criteria"

export interface RetrievedDocument extends ListedDocument {
	/** The text around the match, or null when the criteria hold no query. */
	matchingPassage: string | null
}

/**
 * Without a query, the criteria filter the D1 listing. With a query, AI Search ranks the
 * documents inside its metadata filter, and D1 applies every criterion again to those
 * candidates. D1 is the record, so a stale index item can only drop a result, never add one.
 */
export async function searchDocuments(
	database: ArchiveDatabase,
	searchIndex: SearchIndex,
	{ query, ...filters }: SearchCriteria,
): Promise<Array<RetrievedDocument>> {
	if (query === undefined || query === "") {
		const listing = await queryDocumentListing(database, filters)
		return listing.map((document) => ({ ...document, matchingPassage: null }))
	}
	const response = await searchIndex.search({
		query,
		ai_search_options: {
			retrieval: {
				retrieval_type: "hybrid",
				max_num_results: candidateChunkCount(filters),
				filters: searchIndexFilter(filters),
			},
			// The similarity cache would answer a repeated query without documents indexed since.
			cache: { enabled: false },
		},
	})
	const passages = rankPassages(response.chunks, query)
	if (passages.length === 0) return []
	const candidates = await queryDocumentListing(database, {
		...filters,
		documentIds: passages.map((passage) => passage.documentId),
	})
	const candidatesById = new Map(candidates.map((document) => [document.id, document]))
	return passages
		.flatMap(({ documentId, passage }) => {
			const document = candidatesById.get(documentId)
			return document ? [{ ...document, matchingPassage: passage }] : []
		})
		.slice(0, SEARCH_RESULT_LIMIT)
}
