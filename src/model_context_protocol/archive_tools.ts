import { HttpTransport } from "@tmcp/transport-http"
import { McpServer } from "tmcp"
import { JsonSchemaAdapter } from "tmcp/adapter"
import { z } from "zod"
import { queryArchiveFacets, queryDocumentListing, queryDocumentPage } from "../archive/document_listing"
import { permits } from "../authorization/caller_authorization"
import { connectDatabase } from "../database/client"
import { contentObjectKey } from "../ingestion/source_file"
import { searchDocuments } from "../search/document_search"
import { searchCriteriaSchema } from "../search/search_criteria"
import { readStandingGrant } from "./authorization_grants"
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

const searchArguments = z.strictObject({
	query: z.string().trim().min(1).max(500).describe("What to look for"),
	...documentFilters,
})
const listingArguments = z.strictObject({
	...documentFilters,
	offset: z.number().int().nonnegative().optional().describe("How many documents to skip"),
})
const readingArguments = z.strictObject({ documentId: z.uuid().describe("A document id from another tool") })
const noArguments = z.strictObject({})

type JsonSchema = Awaited<ReturnType<JsonSchemaAdapter<z.ZodType>["toJsonSchema"]>>

/**
 * tmcp converts each input schema on every tools/list. The four schemas never change, so they are
 * converted once when the isolate starts, which keeps that work out of the request's CPU time.
 */
class ConvertedSchemaAdapter extends JsonSchemaAdapter<z.ZodType> {
	readonly #converted = new Map(
		[searchArguments, listingArguments, readingArguments, noArguments].map((schema) => [
			schema as z.ZodType,
			z.toJSONSchema(schema, { io: "input" }) as JsonSchema,
		]),
	)

	override toJsonSchema(schema: z.ZodType): Promise<JsonSchema> {
		const converted = this.#converted.get(schema)
		if (converted === undefined) throw new Error("A tool schema was not converted when the isolate started")
		return Promise.resolve(converted)
	}
}

interface ArchiveToolContext extends Record<string, unknown> {
	database: ArchiveDatabase
	environment: ModelContextEnvironment
	authorizationScope: AuthorizationScope
	origin: string
}

const jsonResult = (value: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(value) }] })

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

/** One server for the isolate. Each request passes its grant's scope as the context the tools read. */
const archiveServer = new McpServer(
	{ name: "schublade", version: "1.0.0", description: "A household's archive of documents" },
	{ adapter: new ConvertedSchemaAdapter(), capabilities: { tools: {} } },
).withContext<ArchiveToolContext>()

function requestContext(): ArchiveToolContext {
	const context = archiveServer.ctx.custom
	if (context === undefined) throw new Error("A tool ran outside a request of the archive")
	return context
}

/** Every tool passes the scope of the grant to the query, so no tool reads past it. */
archiveServer.tool(
	{
		name: "search_documents",
		title: "Search documents",
		description:
			"Search the archived documents by meaning and by exact words such as an IBAN or invoice number, in any language. Returns at most 20 documents with their best matching passage. A document archived in the last few minutes may not be searchable yet.",
		schema: searchArguments,
		annotations: { readOnlyHint: true },
	},
	async (criteria) => {
		const { database, environment, authorizationScope, origin } = requestContext()
		const results = await searchDocuments(database, environment.SEARCH_INDEX, { ...criteria, authorizationScope })
		return jsonResult(results.map((document) => presentDocument(document, origin)))
	},
)

archiveServer.tool(
	{
		name: "list_documents",
		title: "List documents",
		description: `List the archived documents, newest document date first, ${LISTING_PAGE_SIZE} per page. Pass nextOffset from the previous answer to read the next page.`,
		schema: listingArguments,
		annotations: { readOnlyHint: true },
	},
	async ({ offset = 0, ...filters }) => {
		const { database, authorizationScope, origin } = requestContext()
		const { totalDocuments, documents } = await queryDocumentPage(
			database,
			{ ...filters, authorizationScope },
			{ offset, limit: LISTING_PAGE_SIZE },
		)
		const nextOffset = offset + LISTING_PAGE_SIZE
		return jsonResult({
			totalDocuments,
			documents: documents.map((document) => presentDocument(document, origin)),
			...(nextOffset < totalDocuments && { nextOffset }),
		})
	},
)

archiveServer.tool(
	{
		name: "read_document",
		title: "Read a document",
		description: "Read the details of one archived document and the full text extracted from it, as Markdown.",
		schema: readingArguments,
		annotations: { readOnlyHint: true },
	},
	async ({ documentId }) => {
		const { database, environment, authorizationScope, origin } = requestContext()
		const [document] = await queryDocumentListing(database, { documentIds: [documentId], authorizationScope })
		const content = document && (await environment.DOCUMENT_STORAGE.get(contentObjectKey(documentId)))
		// A document outside the grant gets the same answer as one that does not exist.
		if (!document || !content) {
			return { isError: true, content: [{ type: "text", text: `There is no document ${documentId}` }] }
		}
		return jsonResult({ ...presentDocument(document, origin), markdown: await content.text() })
	},
)

archiveServer.tool(
	{
		name: "list_filter_options",
		title: "List filter options",
		description: "List the people, senders, categories, and tags that documents can be filtered by, with their ids.",
		schema: noArguments,
		annotations: { readOnlyHint: true },
	},
	async () => {
		const { database, authorizationScope } = requestContext()
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

// The server keeps nothing between requests, so a GET for a stream of server messages answers 405.
const archiveTransport = new HttpTransport(archiveServer, { path: null, disableSse: true })

const GRANT_IDENTIFIER_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** The props the consent page stored with the token. A zod schema here took a fresh isolate about 3 ms (2026-11-25). */
function holdsGrantProperties(props: unknown): props is { authorizationGrantId: string } {
	if (typeof props !== "object" || props === null || !("authorizationGrantId" in props)) return false
	return typeof props.authorizationGrantId === "string" && GRANT_IDENTIFIER_PATTERN.test(props.authorizationGrantId)
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
	const grant = holdsGrantProperties(context.props)
		? await readStandingGrant(database, context.props.authorizationGrantId)
		: undefined
	if (grant === undefined) return disconnected(origin)
	const { authorizationScope } = grant
	if (!permits({ kind: "oauth_grant", scope: authorizationScope }, "read")) {
		return refusal("This grant does not permit reading the archive")
	}
	if (!grant.deniedTagsAllExist) {
		return refusal("A tag this grant excludes no longer exists. Authorize the client again.")
	}
	const response = await archiveTransport.respond(request, { database, environment, authorizationScope, origin })
	return response ?? new Response("Not found", { status: 404 })
}
