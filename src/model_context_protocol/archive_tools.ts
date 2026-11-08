import { McpServer } from "@modelcontextprotocol/server"
import { createMcpHandler } from "agents/mcp/server"
import { inArray } from "drizzle-orm"
import { z } from "zod"
import { queryArchiveFacets, queryDocumentListing } from "../archive/document_listing"
import { permits } from "../authorization/caller_authorization"
import { connectDatabase } from "../database/client"
import { tags } from "../database/schema"
import { contentObjectKey } from "../ingestion/source_file"
import { searchDocuments } from "../search/document_search"
import { searchCriteriaSchema } from "../search/search_criteria"
import { readGrantedScope } from "./authorization_grants"
import { MODEL_CONTEXT_PROTOCOL_PATH } from "./authorization_server_paths"
import type { FacetOption, ListedDocument } from "../archive/document_listing"
import type { AuthorizationScope } from "../authorization/caller_authorization"
import type { ArchiveDatabase } from "../database/client"
import type { ModelContextEnvironment } from "./authorization_server"

const LISTING_PAGE_SIZE = 50

// searchCriteriaSchema coerces amounts from URL text. The schema that clients read must call them numbers.
const documentFilters = {
	person: searchCriteriaSchema.shape.person.describe("A person id from list_filter_options, or household"),
	sender: searchCriteriaSchema.shape.sender.describe("A sender id from list_filter_options"),
	category: searchCriteriaSchema.shape.category.describe("A category id from list_filter_options"),
	tag: searchCriteriaSchema.shape.tag.describe("A tag id from list_filter_options"),
	earliestDocumentDate: searchCriteriaSchema.shape.earliestDocumentDate.describe("Earliest document date, YYYY-MM-DD"),
	latestDocumentDate: searchCriteriaSchema.shape.latestDocumentDate.describe("Latest document date, YYYY-MM-DD"),
	minimumAmount: z.number().nonnegative().optional().describe("Smallest extracted amount"),
	maximumAmount: z.number().nonnegative().optional().describe("Largest extracted amount"),
}

const jsonResult = (value: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(value) }] })

interface ArchiveToolContext {
	database: ArchiveDatabase
	environment: ModelContextEnvironment
	authorizationScope: AuthorizationScope
	origin: string
}

function presentDocument(document: ListedDocument & { matchingPassage?: string | null }, origin: string) {
	return {
		id: document.id,
		link: `${origin}/documents/${document.id}`,
		title: document.title,
		documentDate: document.documentDate,
		sender: document.senderName,
		category: document.categoryName,
		person: document.personName ?? "household",
		summary: document.summary,
		pageCount: document.pageCount,
		tags: document.tagNames,
		fields: Object.fromEntries(document.fields.map(({ fieldKey, value }) => [fieldKey, value])),
		...(document.matchingPassage && { matchingPassage: document.matchingPassage }),
	}
}

/** A value without a document in the grant must not reach the client, so its name stays hidden too. */
function presentOptions(options: Array<FacetOption>) {
	return options
		.filter((option) => option.documentCount > 0)
		.map(({ id, name, documentCount }) => ({ id, name, documentCount }))
}

/** Every tool passes the scope of the grant to the query, so no tool reads past it. */
function createArchiveServer({ database, environment, authorizationScope, origin }: ArchiveToolContext) {
	const server = new McpServer({ name: "schublade", version: "1.0.0" })

	server.registerTool(
		"search_documents",
		{
			description:
				"Search the archived documents by meaning and by exact words such as an IBAN or invoice number, in any language. Returns at most 20 documents with their best matching passage. A document archived in the last few minutes may not be searchable yet.",
			inputSchema: z.strictObject({
				query: z.string().trim().min(1).max(500).describe("What to look for"),
				...documentFilters,
			}),
			annotations: { readOnlyHint: true },
		},
		async (criteria) => {
			const results = await searchDocuments(database, environment.SEARCH_INDEX, { ...criteria, authorizationScope })
			return jsonResult(results.map((document) => presentDocument(document, origin)))
		},
	)

	server.registerTool(
		"list_documents",
		{
			description: `List the archived documents, newest document date first, ${LISTING_PAGE_SIZE} per page. Pass nextOffset from the previous answer to read the next page.`,
			inputSchema: z.strictObject({
				...documentFilters,
				offset: z.number().int().nonnegative().optional().describe("How many documents to skip"),
			}),
			annotations: { readOnlyHint: true },
		},
		async ({ offset = 0, ...filters }) => {
			const listing = await queryDocumentListing(database, { ...filters, authorizationScope })
			const nextOffset = offset + LISTING_PAGE_SIZE
			return jsonResult({
				totalDocuments: listing.length,
				documents: listing.slice(offset, nextOffset).map((document) => presentDocument(document, origin)),
				...(nextOffset < listing.length && { nextOffset }),
			})
		},
	)

	server.registerTool(
		"read_document",
		{
			description: "Read the details of one archived document and the full text extracted from it, as Markdown.",
			inputSchema: z.strictObject({ documentId: z.uuid().describe("A document id from another tool") }),
			annotations: { readOnlyHint: true },
		},
		async ({ documentId }) => {
			const [document] = await queryDocumentListing(database, { documentIds: [documentId], authorizationScope })
			const content = document && (await environment.DOCUMENT_STORAGE.get(contentObjectKey(documentId)))
			// A document outside the grant gets the same answer as one that does not exist.
			if (!document || !content) {
				return { isError: true, content: [{ type: "text", text: `There is no document ${documentId}` }] }
			}
			return jsonResult({ ...presentDocument(document, origin), markdown: await content.text() })
		},
	)

	server.registerTool(
		"list_filter_options",
		{
			description: "List the people, senders, categories, and tags that documents can be filtered by, with their ids.",
			inputSchema: z.strictObject({}),
			annotations: { readOnlyHint: true },
		},
		async () => {
			const facets = await queryArchiveFacets(database, authorizationScope)
			return jsonResult({
				people: presentOptions(facets.members),
				householdDocumentCount: facets.householdDocumentCount,
				senders: presentOptions(facets.senders),
				categories: presentOptions(facets.categories),
				tags: presentOptions(facets.tags),
			})
		},
	)

	return server
}

const grantPropertiesSchema = z.object({ authorizationGrantId: z.uuid() })

/** The check in authorizationScopeConditions closes the same gap inside each query, without this message. */
async function deniedTagsAllExist(database: ArchiveDatabase, deniedTags: Array<string> = []): Promise<boolean> {
	if (deniedTags.length === 0) return true
	return (await database.$count(tags, inArray(tags.id, deniedTags))) === new Set(deniedTags).size
}

const refusal = (error: string) => Response.json({ error }, { status: 403 })

/** A 401 with this challenge sends the client back through the consent page. */
function disconnected(origin: string): Response {
	return Response.json(
		{ error: "invalid_token", error_description: "This client is no longer connected. Authorize it again." },
		{
			status: 401,
			headers: {
				"WWW-Authenticate": `Bearer error="invalid_token", resource_metadata="${origin}/.well-known/oauth-protected-resource${MODEL_CONTEXT_PROTOCOL_PATH}"`,
			},
		},
	)
}

/** The route the OAuth provider protects: it runs only for a valid access token. */
export async function serveArchiveTools(
	request: Request,
	environment: ModelContextEnvironment,
	context: ExecutionContext,
): Promise<Response> {
	const { origin } = new URL(request.url)
	const database = connectDatabase(environment.DATABASE)
	const grant = grantPropertiesSchema.safeParse(context.props)
	const authorizationScope = grant.success
		? await readGrantedScope(database, grant.data.authorizationGrantId)
		: undefined
	if (authorizationScope === undefined) return disconnected(origin)
	if (!permits({ kind: "oauth_grant", scope: authorizationScope }, "read")) {
		return refusal("This grant does not permit reading the archive")
	}
	if (!(await deniedTagsAllExist(database, authorizationScope.deniedTags))) {
		return refusal("A tag this grant excludes no longer exists. Authorize the client again.")
	}
	return createMcpHandler(() => createArchiveServer({ database, environment, authorizationScope, origin }))(
		request,
		environment,
		context,
	)
}
