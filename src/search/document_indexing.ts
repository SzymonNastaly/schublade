import { and, asc, eq } from "drizzle-orm"
import { documentTags, documents, senders, tags } from "../database/schema"
import { contentObjectKey } from "../ingestion/source_file"
import {
	composeSearchIndexContent,
	documentIdOfItemName,
	searchIndexItemName,
	searchIndexMetadata,
} from "./search_index_item"
import type { ArchiveDatabase } from "../database/client"
import type { IndexedDocument } from "./search_index_item"

type SearchIndexItems = Pick<AiSearchInstance["items"], "upload" | "list">

/** The part of the AI Search binding that Schublade calls, so tests can replace it. */
export interface SearchIndex {
	search: AiSearchInstance["search"]
	// A dev server reaches the remote binding over RPC, where `items` is a promise that rejects
	// a method call until it is awaited. A deployed Worker returns the object itself.
	items: SearchIndexItems | Promise<SearchIndexItems>
}

// Each document costs one R2 read and one AI Search upload, so one request indexes a bounded
// number and stays far below the subrequest limit of a Worker invocation.
const INDEXING_BATCH_SIZE = 100

// AI Search lists at most 50 items per page.
const ITEM_LISTING_PAGE_SIZE = 50

async function readIndexedDocument(
	database: ArchiveDatabase,
	storage: R2Bucket,
	documentId: string,
): Promise<IndexedDocument> {
	const [[document], tagRows, content] = await Promise.all([
		database
			.select({
				id: documents.id,
				title: documents.title,
				documentDate: documents.documentDate,
				senderId: documents.senderId,
				senderName: senders.name,
				categoryId: documents.categoryId,
				personMemberId: documents.personMemberId,
				summary: documents.summary,
			})
			.from(documents)
			.leftJoin(senders, eq(documents.senderId, senders.id))
			.where(and(eq(documents.id, documentId), eq(documents.status, "archived"))),
		database
			.select({ name: tags.name })
			.from(documentTags)
			.innerJoin(tags, eq(documentTags.tagId, tags.id))
			.where(eq(documentTags.documentId, documentId))
			.orderBy(asc(tags.name)),
		storage.get(contentObjectKey(documentId)),
	])
	if (!document) throw new Error(`Document ${documentId} is not archived, so it has nothing to index`)
	if (!content) throw new Error(`Document ${documentId} has no extracted Markdown at ${contentObjectKey(documentId)}`)
	return { ...document, tagNames: tagRows.map((tag) => tag.name), markdown: await content.text() }
}

/**
 * Uploads the archived document to AI Search as `<documentId>.md`. An upload under an existing
 * name replaces that item, so a repeated call converges on the current D1 record.
 */
export async function indexDocument(
	database: ArchiveDatabase,
	storage: R2Bucket,
	searchIndex: SearchIndex,
	documentId: string,
): Promise<void> {
	const document = await readIndexedDocument(database, storage, documentId)
	const items = await searchIndex.items
	await items.upload(searchIndexItemName(documentId), composeSearchIndexContent(document), {
		metadata: searchIndexMetadata(document),
	})
}

/** The status of every item Schublade uploaded, by document identifier. */
async function listIndexedItemStatuses(searchIndex: SearchIndex): Promise<Map<string, AiSearchItemInfo["status"]>> {
	const statuses = new Map<string, AiSearchItemInfo["status"]>()
	const items = await searchIndex.items
	for (let page = 1; ; page++) {
		const { result } = await items.list({ page, per_page: ITEM_LISTING_PAGE_SIZE, source: "builtin" })
		for (const item of result) {
			const documentId = documentIdOfItemName(item.key)
			if (documentId !== undefined) statuses.set(documentId, item.status)
		}
		if (result.length < ITEM_LISTING_PAGE_SIZE) return statuses
	}
}

interface IndexingFailure {
	documentId: string
	reason: string
}

export interface IndexingReport {
	indexedDocumentIds: Array<string>
	/** Documents of this batch that could not be uploaded. The next call attempts them again. */
	failedDocuments: Array<IndexingFailure>
	/** Archived documents still absent from the index after this call, failed ones included. */
	remainingDocumentCount: number
}

/**
 * Uploads every archived document that has no item in AI Search, or whose item failed to
 * index, such as documents archived before the workflow indexed them. A repeated call
 * uploads only what is still missing. A document that cannot be uploaded is reported and
 * does not stop the others.
 */
export async function indexMissingDocuments(
	database: ArchiveDatabase,
	storage: R2Bucket,
	searchIndex: SearchIndex,
): Promise<IndexingReport> {
	const [archivedDocuments, itemStatuses] = await Promise.all([
		database
			.select({ id: documents.id })
			.from(documents)
			.where(eq(documents.status, "archived"))
			.orderBy(asc(documents.createdAt), asc(documents.id)),
		listIndexedItemStatuses(searchIndex),
	])
	const missingDocumentIds = archivedDocuments
		.map((document) => document.id)
		.filter((documentId) => [undefined, "error"].includes(itemStatuses.get(documentId)))
	const indexedDocumentIds: Array<string> = []
	const failedDocuments: Array<IndexingFailure> = []
	for (const documentId of missingDocumentIds.slice(0, INDEXING_BATCH_SIZE)) {
		try {
			await indexDocument(database, storage, searchIndex, documentId)
			indexedDocumentIds.push(documentId)
		} catch (error) {
			failedDocuments.push({ documentId, reason: error instanceof Error ? error.message : String(error) })
		}
	}
	return {
		indexedDocumentIds,
		failedDocuments,
		remainingDocumentCount: missingDocumentIds.length - indexedDocumentIds.length,
	}
}
