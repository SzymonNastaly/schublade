# Schublade

Schublade, short for *Schnell und Bequem Lagern aller Dokumente elektronisch*, is a self-hosted, automated document archive built on Cloudflare Workers, R2, D1, Workflows, and AI Search.

For design rationale, trade-offs, and system architecture, read [VISION.md](VISION.md).

## Naming specification

Every identifier in this repository, across files, scripts, directories, functions, variables, classes, database columns, bindings, commits, and branches, must use precise professional vocabulary. Choose the exact technical term a 1972 IBM systems engineer would write in a formal specification. Avoid slang, casual shorthand, abbreviations, metaphors, or conversational idioms. For example, a script that provisions infrastructure is `provision_environment.ts`, not `setup.ts`, and a module that coordinates client state is `archive_coordinator.ts`, not `archive_hub.ts`.

## Technical stack

| Layer | Technology |
| --- | --- |
| Runtime | Cloudflare Workers (`workerd`), Durable Objects, Cloudflare Workflows |
| Object storage | Cloudflare R2 (`env.DOCUMENT_STORAGE`) for original PDFs and images |
| Relational database | Cloudflare D1 (`env.DATABASE`) with Drizzle ORM and `drizzle-zod` |
| Search index | Cloudflare AI Search (`env.SEARCH_INDEX`) with hybrid BM25 and Vectorize indexing |
| Inference and OCR | Workers AI through AI Gateway (`env.AI_RUNTIME`): `toMarkdown()`, `@cf/moondream/moondream3.1-9B-A2B` page transcription, and structured classification with the Vercel AI SDK and `workers-ai-provider` |
| PDF page rendering | PDFium compiled to WebAssembly (`@embedpdf/pdfium`) for scanned pages without a text layer |
| Electronic mail | Cloudflare Email Routing (`email()` handler) and `postal-mime` |
| Document rendering | Cloudflare Browser Run (`env.BROWSER_RENDERER`) for body-only HTML email receipts |
| Authentication | Cloudflare Access JWT verification for browser traffic, scoped bearer and OAuth tokens for `/api/documents/ingest` and `/mcp` |
| User interface | TanStack Start, React 19, Cloudflare Kumo (`@cloudflare/kumo`), Tailwind CSS v4, Phosphor Icons (`@phosphor-icons/react`) |
| Build and deployment | `cf` CLI pinned to an exact version, `cloudflare.config.ts` (open beta), Vite 8, `@cloudflare/vite-plugin`, Vitest, pnpm |

## Cloudflare bindings

All bindings are declared in `cloudflare.config.ts` and imported on the server from `cloudflare:workers`:

| Binding | Type | Purpose |
| --- | --- | --- |
| `DATABASE` | D1 Database | Relational tables for documents, senders, categories, tags, extracted fields, household members, tokens, and grants |
| `DOCUMENT_STORAGE` | R2 Bucket | Original uploaded PDFs, images, and rendered HTML email PDFs |
| `SEARCH_INDEX` | AI Search Instance | Hybrid vector and BM25 search index populated via `items.upload()`, with the custom metadata fields `person`, `sender`, `category`, and `document_date` |
| `AI_RUNTIME` | Workers AI | `toMarkdown()` conversion, Moondream page transcription, and language model calls through AI Gateway |
| `BROWSER_RENDERER` | Browser Run | Renders body-only HTML emails into archival PDFs |
| `DOCUMENT_INGESTION_WORKFLOW` | Workflow | Executes `DocumentIngestionWorkflow` for text extraction, OCR, classification, and indexing |
| `ARCHIVE_COORDINATOR` | Durable Object | Runs `ArchiveCoordinator` to broadcast workflow state transitions over WebSocket |
| `AUTHORIZATION_STORE` | Durable Object | Runs `AuthorizationStore` to persist OAuth clients, grants, and tokens for `/mcp` |

## D1 relational schema

The relational schema in `src/database/schema.ts` defines nine tables:

- **`documents`.** Stores `id`, `title`, `document_date`, `sender_id`, `category_id`, `person_member_id` (null for `household`), `summary`, `storage_object_key`, `mime_type`, `byte_size`, `page_count`, `status`, `verification_reason`, `created_at`, and `updated_at`.
- **`senders`.** Stores `id`, `name`, `normalized_name`, and `created_at`.
- **`categories`.** Stores `id`, `name`, `normalized_name`, `expected_fields_json`, and `created_at`.
- **`tags`.** Stores `id`, `name`, `normalized_name`, `color_hex`, and `created_at`.
- **`document_tags`.** Joins `document_id` and `tag_id`.
- **`extracted_fields`.** Stores `id`, `document_id`, `field_key`, `field_type`, `value_text`, `value_number`, and `confidence_score`.
- **`household_members`.** Stores `id`, `display_name`, `addressee_names_json`, and `created_at`.
- **`api_tokens`.** Stores `id`, `description`, `token_sha256`, `authorization_scope_json`, `last_used_at`, and `created_at`.
- **`authorization_grants`.** Stores `id`, `client_id`, `client_name`, `authorization_scope_json`, `created_at`, and `revoked_at`.

## Domains and environments

The `schublade.org` zone on Cloudflare hosts the project website and the reference staging environment:

| Hostname | Environment mode | Purpose |
| --- | --- | --- |
| `schublade.org` | `landing` | Public landing page and project documentation |
| `staging.schublade.org` | `staging` via `cf deploy --mode staging` | Staging and development deployment protected by Cloudflare Access, with inbound Email Routing on `schublade.org` |

## Repository layout

```text
src/
	server.ts                                Worker entry: Access verification, /agents/*, /api/documents/ingest, /mcp, inbound mail
	database/
		schema.ts                              Drizzle SQLite table definitions and drizzle-zod schemas
		client.ts                              D1 database connection factory
	workflows/
		document_ingestion_workflow.ts         Durable ingestion pipeline: toMarkdown, vision OCR, classification, indexing
	durable_objects/
		archive_coordinator.ts                 ArchiveCoordinator Durable Object for WebSocket state synchronization
		authorization_store.ts                 AuthorizationStore Durable Object for OAuth 2.1 credentials
	inference/
		model_router.ts                        Workers AI model factory routed through AI Gateway
		page_rasterizer.ts                     PDFium WebAssembly rendering of scanned PDF pages to PNG images
		text_recognizer.ts                     Per-page Moondream transcription of page and camera images
		document_classifier.ts                 Structured extraction prompt and Zod output schema
	operations/
		operation_registry.ts                  Central procedure registry for server functions, REST endpoints, and MCP
		access_control.ts                      AuthorizationScope verification and query predicate injection
	mcp_server/
		authorization_provider.ts              OAuth 2.1 provider and /mcp protocol handler
	routes/
		_app/                                  Three-pane desktop interface and responsive mobile Drawer views
		api/documents.ingest.ts                Token-authenticated multipart document ingestion endpoint
	components/                              Document table, PDF and Markdown inspection pane, verification records, mobile bar
	utilities/
		types.ts                               Shared domain types
		server_functions.ts                    TanStack Start typed RPC procedures
		viewport.ts                            useMobileViewport hook and responsive layout helpers
scripts/
	provision_environment.ts                 Interactive resource provisioning for D1, R2, AI Search, AI Gateway, Access, and household members
	generate_test_documents.ts               Deterministic generator for the synthetic test documents
test_fixtures/
	documents/                               Synthetic, anonymous test documents and expected_extraction.json
cloudflare.config.ts                       Typed Worker, Workflow, Durable Object, and binding specification
VISION.md                                  System architecture, design rationale, and operational boundaries
IMPLEMENTATION_PLAN.md                     Build order, quality gates, and verification for each phase
```
