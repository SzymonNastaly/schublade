import { and, asc, eq } from "drizzle-orm"
import { connectDatabase } from "../database/client"
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

// Each page is one subrequest. 100 pages hold 5,000 items, and a listing that does not end
// stops here instead of at the subrequest limit of the Worker invocation.
const MAXIMUM_LISTING_PAGES = 100

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

/**
 * The status of every item Schublade uploaded, by document identifier. A short page does not
 * prove the end of the listing, so only an empty page ends it.
 */
async function listIndexedItemStatuses(searchIndex: SearchIndex): Promise<Map<string, AiSearchItemInfo["status"]>> {
	const statuses = new Map<string, AiSearchItemInfo["status"]>()
	const items = await searchIndex.items
	for (let page = 1; page <= MAXIMUM_LISTING_PAGES; page++) {
		const { result } = await items.list({ page, per_page: ITEM_LISTING_PAGE_SIZE, source: "builtin" })
		if (result.length === 0) return statuses
		for (const item of result) {
			const documentId = documentIdOfItemName(item.key)
			if (documentId !== undefined) statuses.set(documentId, item.status)
		}
	}
	// Every document missing from an incomplete listing would look absent and be uploaded again.
	throw new Error(
		`AI Search listed more than ${MAXIMUM_LISTING_PAGES} pages of items, so the documents it lacks are unknown`,
	)
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

type IndexingEnvironment = Pick<Env, "DATABASE" | "DOCUMENT_STORAGE"> & { SEARCH_INDEX: SearchIndex }

/**
 * Answers POST /api/search_index. A browser sends Origin with every POST, and a page on another
 * site must not start billed uploads through the Access session of a household member. A
 * script sends no Origin.
 */
export async function receiveIndexingRequest(environment: IndexingEnvironment, request: Request): Promise<Response> {
	const origin = request.headers.get("Origin")
	if (origin !== null && origin !== new URL(request.url).origin) {
		return Response.json({ error: `A page on ${origin} may not index documents` }, { status: 403 })
	}
	return Response.json(
		await indexMissingDocuments(
			connectDatabase(environment.DATABASE),
			environment.DOCUMENT_STORAGE,
			environment.SEARCH_INDEX,
		),
	)
}

/**
 * The scheduled run of the backfill, which indexes documents that AI Search lacks or failed to
 * index without a signed-in request, and logs one line per run.
 */
export async function indexMissingDocumentsOnSchedule(environment: IndexingEnvironment): Promise<void> {
	const report = await indexMissingDocuments(
		connectDatabase(environment.DATABASE),
		environment.DOCUMENT_STORAGE,
		environment.SEARCH_INDEX,
	)
	const failures = report.failedDocuments.map(({ documentId, reason }) => `${documentId}: ${reason}`)
	console.log(
		`Scheduled search indexing: ${report.indexedDocumentIds.length} indexed, ${failures.length} failed, ` +
			`${report.remainingDocumentCount} remaining${failures.length > 0 ? `. ${failures.join("; ")}` : ""}`,
	)
}
