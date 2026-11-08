# Agent instructions

Schublade is a self-hosted document archive that runs as one Cloudflare Worker. TanStack Start serves the interface, D1 holds the relational records, R2 holds the original files, AI Search indexes the text, and a Workflow runs ingestion. Read this file before you change code. The `cf` command-line interface and `cloudflare.config.ts` are newer than most training data, so look up what you are not sure of (see [Documentation lookup order](#documentation-lookup-order)).

VISION.md explains the architecture and IMPLEMENTATION_PLAN.md the build order. `cloudflare.config.ts` is the source of truth for bindings, and `src/database/schema.ts` is the source of truth for tables.

## Rules, most important first

1. **Fail closed.** Every browser request needs a valid Cloudflare Access assertion. When `ACCESS_TEAM_DOMAIN` or `ACCESS_AUD` is blank, the Worker rejects every request with 403. Never add a fallback identity, a demonstration user, or a path that skips `requireAccess` in production code. The only exemption is `VITE_ACCESS_DEVELOPMENT_EXEMPTION`, which exists only under `import.meta.env.DEV` and is absent from builds.
2. **Every resource binding needs an identifier.** `cf deploy` provisions a new, empty resource for any D1 or R2 binding without an identifier and never records it. Identifiers come from the git-ignored `schublade.deploy.json`, which `pnpm run provision` writes. `cloudflare.config.ts` throws in every build mode while an identifier is missing. Keep that check, and extend it when you add a resource binding.
3. **Never call billed Cloudflare services in tests.** Workers AI, Browser Run, and AI Search bill per request. The workerd test project sets `remoteBindings: false`, and tests replace those bindings with recorded responses.
4. **Follow the naming specification.** The specification reads:

   Every identifier in this repository, across files, scripts, directories, functions, variables, classes, database columns, bindings, commits, and branches, must use precise professional vocabulary. Choose the exact technical term a 1972 IBM systems engineer would write in a formal specification. Avoid slang, casual shorthand, abbreviations, metaphors, or conversational idioms. For example, a script that provisions infrastructure is `provision_environment.ts`, not `setup.ts`, and a module that coordinates client state is `archive_coordinator.ts`, not `archive_hub.ts`.

5. **Use `cf`, not `wrangler`.** Wrangler cannot read `cloudflare.config.ts`. Do not create `wrangler.jsonc` and do not run `wrangler` commands.
6. **Commit straight to `main`.** Schublade uses no branches and no pull requests. Each commit is one change that passes `pnpm check`, with an imperative subject and a body that explains why. Push only when the user asks. The pre-push hook runs `pnpm check`. Never bypass it.
7. **Keep the test suite lean.** `pnpm check` finishes in under 60 seconds. Write one test per behavior, call the code as its users do, and assert literal values from the test or from `test_fixtures/documents/expected_extraction.json`. Use the workerd project only for code that needs the Workers runtime, such as bindings or WebAssembly. No snapshot tests and no browser tests.
8. **The Moondream binding returns an event stream.** `env.AI_RUNTIME.run()` for `@cf/moondream/moondream3.1-9B-A2B` returns server-sent events even without `stream: true`. Every `chunk.answer` repeats the full answer so far, so `parseMoondreamEventStream` keeps the last one.
9. **Generate migrations with drizzle-kit and apply them with `cf`.** Never run `drizzle-kit push` or `drizzle-kit migrate`, and never edit an applied migration.
10. **`cloudflare:workers` is server-only.** Import it only from server functions, the Worker entry, Workflows, and Durable Objects, never from a component.
11. **Edit the human-facing documents only when the user asks.** README.md, VISION.md, and IMPLEMENTATION_PLAN.md are otherwise written outside coding sessions. When a change makes one of them wrong, list the edits it needs in your report.

## Repository layout

```text
src/
	server.ts                              Worker entry: request dispatch with the caller as TanStack Start request context; the scheduled backfill; the email handler; the Workflow and Durable Object classes
	request_dispatch.ts                    Cross-site refusal, then bearer tokens for exactly /api/documents/ingest, the OAuth paths of /mcp, Access for every other path, and the archive changes socket and consent page behind it
	request_dispatch.workerd.test.ts
	ambient_declarations.d.ts              Types for import.meta.env, the PDFium WebAssembly import, and PDF fixture imports
	authorization/
		caller_authorization.ts              Caller union, PermissionLevel order, AuthorizationScope schema, permits(), and the level of each server function
		caller_authorization.test.ts
	authentication/
		access_verification.ts               requireAccess: Cloudflare Access assertion verification with jose; hands on a member_session caller
		access_verification.test.ts
		api_tokens.ts                        API token issuance, listing, revocation, and bearer authentication with hourly last-use records
		api_tokens.workerd.test.ts
		cross_site_requests.ts               crossSiteRequestRejection: 403 for a write or WebSocket upgrade whose Origin names another site
		cross_site_requests.test.ts
	database/
		schema.ts                            The nine Drizzle tables and their drizzle-zod insert schemas
		client.ts                            Drizzle bound to env.DATABASE, and connectDatabase for a passed binding
		database_migrations.workerd.test.ts  Every migration applied in order to rows written under the first schema
	archive/
		archive_changes.ts                   The socket path, the connection to the household's coordinator, and the announcement that tells open browsers to read the archive again
		archive_changes.workerd.test.ts
		document_listing.ts                  The document listing query with its filters, the facet options with their archived document counts, and the status records of given documents
		document_listing.workerd.test.ts
		document_representation.ts           The original file, the extracted Markdown, or a first-page thumbnail rendered on first request, served with nosniff and a sandbox policy
		document_representation.workerd.test.ts
		verification_items.ts                The Pending verification entries as one union by reason, and their count
		verification_items.workerd.test.ts
		taxonomy_maintenance.ts              Confirm, rename (proposing a merge on a name clash), merge, and delete senders, categories, and tags
		taxonomy_maintenance.workerd.test.ts
		document_revision.ts                 A member's revision of a document with its immediate reindex, and document deletion
		document_revision.workerd.test.ts
	ingestion/                             Ingestion domain; all but document_ingestion.ts, document_upload.ts, token_ingestion.ts, inbound_mail.ts, and mail_rendering.ts are pure and tested in Node
		document_lifecycle.ts                Document status transition table
		source_file.ts                       Accepted file kinds, their leading-byte signatures, and R2 object keys
		document_text.ts                     Per-page text source (conversion, PDFium text layer, or recognition) and Markdown assembly
		document_classification.ts           Extracted field set, standard categories, output schema, and normalization
		classification_prompt.ts             Classification prompt with the taxonomy, the members, the schema, and the email that delivered a document
		taxonomy_resolution.ts               Name normalization and matching against sender, category, and tag rows
		verification_assessment.ts           Illegible required fields and the precedence of the three verification reasons
		document_ingestion.ts                The workflow steps and their D1 and R2 writes, the workflow start, and the retry of a failed document
		document_ingestion.workerd.test.ts   Step order with recorded Workers AI responses
		document_upload.ts                   Multipart uploads: size limits and 20 files per request, then per file identification, R2 write, row, and workflow start
		document_upload.workerd.test.ts
		token_ingestion.ts                   POST /api/documents/ingest: bearer token, ingest level, then the multipart upload
		token_ingestion_path.ts              The one path Access bypasses, shared with the provisioning script
		mail_message.ts                      Parse limits for mail, the classification context of a message, and the page printed for an email without a usable attachment
		mail_message.test.ts
		mail_rendering.ts                    Removes active markup and prints a page to a PDF on Browser Run
		inbound_mail.ts                      email() handler: envelope rejection before any read, sender authentication on the headers alone, a parse within limits, attachments, awaiting_rendering, Message-ID idempotency
		inbound_mail.workerd.test.ts
	search/                                AI Search indexing and retrieval; search_index_item.ts and search_criteria.ts are pure and tested in Node
		search_index_item.ts                 Item name, Markdown content, and custom metadata of an indexed document
		search_criteria.ts                   Search parameter schema, URL search parsing, the AI Search filter, and passage excerpts
		document_indexing.ts                 SearchIndex port, the index step and indexed_at, item removal, indexMissingDocuments for missing, failed, and stale documents, its callers
		document_indexing.workerd.test.ts
		document_search.ts                   Hybrid AI Search query joined with D1, or the D1 listing without a query
		document_search.workerd.test.ts
		in_memory_search_index.ts            A SearchIndex for workerd tests that keeps items in memory
	model_context_protocol/                The /mcp server and its OAuth flow; authorization_server_paths.ts and grant_selection.ts are pure
		authorization_server_paths.ts        The paths an OAuth client reaches without Access, shared with the provisioning script
		authorization_server.ts              OAuthProvider options built from the origin of the request; the household is the subject of every grant
		archive_tools.ts                     The four read-only tools, each passing the scope of the grant to its query
		grant_consent.ts                     The consent page behind Access: shows the request and records the decision
		consent_page.tsx                     Static HTML of the consent page, escaped by React
		grant_selection.ts                   The scope a consent form grants and the sentence that describes it
		grant_selection.test.ts
		authorization_grants.ts              The D1 record of each grant: the scope a request reads, and what Settings lists and disconnects
		archive_access.workerd.test.ts       Registration, consent, token, and each tool under a restricted grant
	interface/
		document_search_controls.tsx         Search input with the / and Cmd+K shortcuts, the filter row, and the removable active filters
		active_filter_presentation.ts        The Person options with Household, and the label of each active filter from a table keyed by criterion
		active_filter_presentation.test.ts
		document_list.tsx                    Stacked rows below the md breakpoint, the document table from md upward; every row links to its document page
		document_thumbnail.tsx               A small picture of the first page, or a file icon when there is none
		document_formatting.ts               Dates, amounts, periods, and IBANs as readers expect them, in one fixed locale so server and browser render the same text
		document_formatting.test.ts
		page_load_failure.tsx                What a page shows when its loader failed; it recovers on the next announcement
		archive_navigation.tsx               All documents, Pending verification with its count, and Settings
		document_original.tsx                The original file in the document box, or the note that an email has no PDF yet, and the Open original link
		pdf_page_box.tsx                     PDF.js in a box of constant size: sideways pages below md, stacked pages from md upward, only pages near the visible one drawn
		document_details.tsx                 The document's details: reading or editing, the Pending verification banner, and Show extracted text
		document_detail_presentation.ts      Extracted field labels, the rows of the reading state, and the fields the form offers
		document_detail_presentation.test.ts
		document_revision_form.tsx           The details' edit form and the confirmed document deletion
		action_confirmation.tsx              The dialog that names what an irreversible action does before it runs
		document_status_presentation.ts      Status badge labels and the plain sentence for each failure reason
		document_status_updates.ts           The tab's one socket, useArchiveChanges, and useDocumentStatusUpdates, the only code that knows how updates arrive
		tracked_uploads.ts                   The union of tracked upload rows and its reducer
		tracked_uploads.test.ts
		document_file_picker.tsx             The hidden file input and the control that opens it; on a phone the system picker offers camera, photos, and files
		phone_action_bar.tsx                 Search, Pending verification, and Upload document, fixed to the bottom of a phone screen
		upload_tray.tsx                      Upload context provider, the tray, and the Retry and Delete controls of a failed document
		verification_entries.ts              Pure functions over the Pending verification union: entry key, list summary, new sender selection, and the review position
		verification_entries.test.ts
		verification_entry_controls.tsx      What one entry asks and the controls that resolve it; deletions and merges ask first; each document links to its page
		new_sender_confirmation.tsx          The dialog that confirms the ticked new senders together
	utilities/
		server_functions.ts                  TanStack Start server functions, each refused below its level by authorizeOperation
		server_functions.workerd.test.ts     Each server function run through TanStack Start's server path with callers below and at its level
	routes/
		__root.tsx                           HTML document shell with the manifest links, the upload provider and tray, the phone action bar, and the Pending verification count for the navigation
		index.tsx                            Archive page: search controls, document list, and upload control
		settings.tsx                         Settings page: issue an ingest token shown once, list and revoke tokens, list and disconnect the clients of /mcp
		verification.tsx                     Pending verification overview: Review and Confirm new senders, and one compact row per entry that opens its review
		verification_.review.tsx             /verification/review: one entry at a time with its document and controls, the entry parameter, Skip remembered in component state
		documents.$documentId.tsx            Document page: title, summary, the original beside its details, then the navigation; after a deletion, the previous page or the archive
		api/documents.ts                     GET searches or lists documents by the searchCriteriaSchema parameters, POST accepts multipart uploads in fields named files
		api/documents.$documentId.$representation.ts   GET the original file or the extracted Markdown
		api/search_index.ts                  POST indexes archived documents that AI Search lacks and reports failedDocuments; repeat while it indexes some
	router.tsx                             Router factory
	routeTree.gen.ts                       Generated by `pnpm dev` and `pnpm build`; do not edit
	styles.css                             Tailwind CSS v4 and Kumo styles
	workflows/
		document_ingestion_workflow.ts       DocumentIngestionWorkflow, which passes its env to ingestDocument
	durable_objects/
		archive_coordinator.ts               ArchiveCoordinator: holds the WebSockets of open browsers and passes one signal to them
	inference/
		page_rasterizer.ts                   PDFium WebAssembly: page text extraction and page rendering to PNG
		page_rasterizer.workerd.test.ts
		text_recognizer.ts                   Moondream page transcription, event stream parsing, and euro sign repair
		text_recognizer.test.ts
		document_classifier.ts               generateText with workers-ai-provider through AI Gateway
drizzle/                                 Generated SQL migrations and drizzle-kit snapshots
scripts/
	provision_environment.ts               `pnpm run provision`: creates or reuses the resources, deploys behind Access, custom hostname, Email Routing, token ingestion bypass
	provisioning_requests.ts               Access bodies, protected hostnames, zone candidates, routing rule matching, and the MX records that block Email Routing, tested in Node
	generate_test_documents.ts             Deterministic generator for test_fixtures/documents
	evaluate_extraction.ts                 `pnpm evaluate:extraction`: uploads the test documents to a dev server and scores the results
	evaluate_search.ts                     `pnpm evaluate:search`: archives and indexes the test documents on a dev server, then checks fixed searches
	test_document_generation/              Document catalog, page layout, and scan and photograph simulation
test_fixtures/
	documents/                             Synthetic test documents and expected_extraction.json
	inference_recordings/                  Workers AI responses recorded from the test documents for workerd tests
.agents/skills/                          Project skills; .claude/skills links here
.github/workflows/check.yml              Runs `pnpm check` on each push to main
cloudflare.config.ts                     Worker, bindings, Cron Trigger, Workflow and Durable Object exports, and the deployment guard
drizzle.config.ts                        drizzle-kit configuration
vite.config.ts                           Vite plugins, dev server port, Worker source maps
vitest.config.ts                         The node and workerd test projects
eslint.config.js, .prettierrc.json, knip.json, tsconfig.json
```

## Things that will bite you

- **Configuration modes.** Builds evaluate `cloudflare.config.ts` in `production` mode or the `--mode` they receive. `cf dev` evaluates it in `development` mode, and `cf workers types` evaluates it without a mode. Only build modes require the identifiers in `schublade.deploy.json`.
- **AI Search has no local simulation.** Every local mode binds `SEARCH_INDEX` to the remote AI Search instance `schublade-development`, which must exist on the signed-in account with the same four custom metadata fields as a provisioned instance. A dev server therefore never writes into the index of a deployment, but the local D1 database and that shared index can disagree. Searches and uploads against it are billed.
- **Await `SEARCH_INDEX.items` before calling it.** In development, the remote binding answers over RPC, and `env.SEARCH_INDEX.items.list()` fails with `The RPC receiver does not implement the method "list"`. `await env.SEARCH_INDEX.items` first, as `document_indexing.ts` does. A deployed Worker returns the object itself, so the await costs nothing there.
- **AI Search facts the search relies on.** An upload under an existing item name replaces the item and keeps its identifier. A `datetime` metadata field accepts `2026-09-22T00:00:00Z`, stores milliseconds, and filters correctly with ISO 8601 strings, not with Unix seconds. While an item reindexes, its old and new chunks can both match, so results are grouped by item name. Indexing an upload took 73 to 145 seconds on the development instance when 12 arrived together, so a document archived a moment ago is not yet searchable. Every search disables the similarity cache, which would answer a repeated query without the documents indexed since.
- **A new route needs a regenerated route tree.** Only `pnpm dev` and `pnpm build` rewrite `src/routeTree.gen.ts`, and until then `tsc` rejects the path that the new file passes to `createFileRoute`. Without a dev server, regenerate it with `node --input-type=module -e 'import { resolveConfig } from "vite"; import { tanstackStart } from "@tanstack/react-start/plugin/vite"; await resolveConfig({ configFile: false, root: process.cwd(), plugins: [tanstackStart()] }, "build")'` and commit the result with the route.
- **URL search parameters are parsed in `parseSearchString`.** TanStack Router merges every parameter it parses into the validated search of each route, so `validateSearch` alone cannot drop an unknown or unreadable one, and the default parser reads `1.50` as a number. `src/router.tsx` therefore passes `parseSearchString` and `composeSearchString` from `search_criteria.ts`. A new search parameter must pass through `parseSearchString`, as `entry` of the review page does, and the archive loader reads its criteria through `parseSearchParameters`, because `retrieveDocuments` refuses any other key.
- **A document is stale while its updated_at exceeds its indexed_at, or its indexed_at is null.** The index step reads updated_at before anything else, uploads, and stores that revision only while updated_at still holds it. When the revision changed during the upload, AI Search may have accepted an older upload last, so the step clears indexed_at and raises updated_at, which keeps every overlapping upload from recording its revision too. Every update raises updated_at by at least one second, so a revision written in the second of an upload still counts as stale. A write that changes nothing AI Search reads, such as recording indexed_at, sets `updatedAt` to its own column, or the backfill uploads the document again. A merge or rename marks its documents stale with `succeedingModificationTime()` instead of uploading each one.
- **`cf dev` needs a Cloudflare login.** `AI_RUNTIME`, `BROWSER_RENDERER`, and `SEARCH_INDEX` are remote in development, so `cf dev` opens a remote preview session on the signed-in account. It deploys nothing.
- **Local development runs as `schublade-development`.** The remote preview of a Worker that shares a deployed name sits behind that deployment's Access application and fails without a service token. `cloudflare.config.ts` therefore names the Worker `schublade-development` in every local mode, and `pnpm evaluate:extraction` addresses the local Workflow under that name. Never provision an environment with that worker name.
- **Local development does not run the Cron Trigger.** Every 15 minutes a deployed Worker starts up to 20 emails still awaiting rendering and runs the scheduled backfill, which uploads up to 100 archived documents that AI Search lacks, failed to index, or holds a stale revision of, and logs one `Scheduled search indexing:` line. To run it once on a dev server, request `http://localhost:3000/cdn-cgi/local/scheduled?format=json`. It lists and uploads into the billed development instance.
- **Only `/api/documents/ingest` and the OAuth paths skip Access.** `request_dispatch.ts` compares the exact pathname with the token ingestion path and with `ACCESS_BYPASSING_PATHS`. The Access application covers those paths through `ACCESS_BYPASS_DESTINATIONS`. Access bypasses those paths through the applications "schublade <worker>: token ingestion" and "schublade <worker>: model context protocol", and their subpaths inherit the bypass, so the Worker keeps them behind `requireAccess`. The consent page at `/authorize` stays behind Access. Never widen a comparison to a prefix; `request_dispatch.workerd.test.ts` fails when you do.
- **`/mcp` is stateless and read-only.** `McpAgent` is deprecated in `agents` 0.33, so `archive_tools.ts` builds an `McpServer` for each request through `createMcpHandler` from `agents/mcp/server`, and no Durable Object takes part. `@modelcontextprotocol/server` stays at the exact version that the installed `agents` release names as its peer.
- **D1 decides whether a grant stands, and every tool must pass the scope.** `@cloudflare/workers-oauth-provider` requires the binding name `OAUTH_KV` and keeps clients and tokens there, but KV is eventually consistent, so a refresh at a location that still caches a deleted grant writes it back. `authorization_grants` therefore holds the scope and `revoked_at`, the token carries only the row identifier in its `props`, and `serveArchiveTools` reads that row on every request. Disconnecting a client leaves its KV tokens to expire. Scope lists hold record identifiers, so a rename leaves a grant intact, and they bind as one JSON parameter through `json_each`, because D1 allows 100 bound parameters per query. A query without `authorizationScope` reads the whole archive, so a new tool passes it to every query. A merge deletes the tag it folds away, so a scope whose denied tag no longer exists admits nothing, and each scoped statement asks that itself.
- **`cf dev` can scramble a large remote response.** In local runs, the PDF from the remote `BROWSER_RENDERER` binding reached the Worker with 8 KiB chunks out of order in 3 of 4 renderings, which shifted its objects by multiples of 8192 bytes. The same request through `cf browser-run quick-action pdf` was intact. PDFium repairs such a file, but PDF.js and `toMarkdown` then read some fonts as text such as `6XEMHFW` for `Subject`. `pdftotext` warns about the cross-reference table of such a file, so check that before suspecting the markup.
- **Mail markup is made inert before printing.** `printMail` removes scripts, `noscript`, frames, refresh tags, and `<base>` with `HTMLRewriter`, because `allowResourceTypes` must include `document` or Browser Run prints a blank page, and a frame is a document too. It repeats until the output stops changing, because removing a tag can join the text around it into a new tag. `HTMLRewriter` exists only in workerd, so `mail_rendering.ts` is tested there.
- **The manifest link needs `crossOrigin: "use-credentials"`.** Access protects `public/` like everything else, and a browser sends no cookie for a manifest without that attribute.
- **Tokens are bound to the origin of the request.** `authorizationServerOptions` receives it from `request.url`, so a local dev server works at `http://localhost:3000` with no configuration and a token issued for one hostname is refused on another.
- **`pnpm dev` waits for an answer before a pending migration.** In a tool that cannot type into the terminal, start it with `CI=true VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev`, which accepts the prompt.
- **PDF.js stays on `pdfjs-dist` 6.5.438, legacy build.** The standard build hung while drawing in iOS Safari. Version 6 needs both `workerSrc` and `rendererSrc`, and it decodes CCITT, JBIG2, and JPX images, the usual encodings of scans, only through the WebAssembly files that `BundledDecoderFactory` in `pdf_page_box.tsx` serves. Without them those images draw blank and nothing fails.
- **`vi.mock` fails in the workerd test project.** Vitest's module mocker calls `AsyncLocalStorage.disable()`, which workerd does not implement. Spy on a module export with `vi.spyOn` and import the module under test afterwards, as `server_functions.workerd.test.ts` does.
- **Server functions read the caller through a cast.** The Worker entry passes `{ caller }` to `handler.fetch` as request context, and TanStack Start delivers it to server functions at run time, but types their `context` as undefined. `authorizeOperation` in `caller_authorization.ts` reads it and refuses a request without a caller.
- **Cloudflare's results live in the block Email Routing prepends.** On the first live delivery, from Gmail to staging, Email Routing prepended Received, ARC-Seal, ARC-Message-Signature, ARC-Authentication-Results, Received-SPF, Authentication-Results, and X-CF-SpamH-Score above Gmail's own Received header. Every relay prepends, so a sender's headers always sit below that second Received header. `inbound_mail.ts` therefore requires a Received header first, takes the block up to the next Received header, and rejects a message without one. It trusts only the one Authentication-Results header from `mx.cloudflare.net` inside the block and ignores every Authentication-Results header below it. The one From mailbox must equal the envelope sender. Every delivery the handler reads logs one `Inbound mail header layout` line with the names of its first 12 headers, the position and authserv-id of each Authentication-Results and ARC-Authentication-Results header, the trusted dmarc result unless it names a mailbox, and whether the delivery was admitted. Email Routing delivers mail from domains whose DMARC policy is `none`, such as gmail.com, so the allowlist means nothing without the `dmarc=pass` check.
- **Test inbound mail locally through the email endpoint.** Set `ingestionEmailAddress` and `accessEmails` in `schublade.deploy.json`, start `pnpm dev`, and post a raw RFC 5322 message: `curl -X POST "http://localhost:3000/cdn-cgi/local/email?from=<sender>&to=<ingestion address>" --data-binary @message.eml`. The endpoint does not add Email Routing's headers, so the message must open with the block Email Routing prepends: a `Received: ... by mx.cloudflare.net` header and an `Authentication-Results: mx.cloudflare.net; dmarc=pass header.from=<sender domain>` header. The sender's own Received header follows, then a From that is the `from` of the request and a `Message-ID`. `emailRoutingBlock` in `inbound_mail.workerd.test.ts` has the full block. The response states whether the Worker accepted or rejected the message.
- **The email trigger owns the routing rule.** With `ingestionEmailAddress` set, `cf deploy` creates and updates the Email Routing rule for the address. It asks before replacing or deleting a rule and fails in a non-interactive run, such as `pnpm run provision`; run `pnpm run deploy` in a terminal to confirm. Leaving the address unset leaves the trigger out and the rules alone.
- **A custom hostname turns workers.dev off.** With `customHostname` set, build modes add the Workers custom domain and `workersDev: false`. `pnpm run provision` extends the Access application to a new hostname before the deployment that moves the route and removes old hostnames only afterwards.
- **Local development returns 403.** The Access variables are blank locally, so `GET /` returns `Access denied: access_unconfigured`. Start the dev server with `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev` to see the interface.
- **One local database identifier.** Local development simulates D1 under `00000000-0000-4000-8000-000000000000`. The constant lives in `cloudflare.config.ts` and in the `database:migrate:local` script. Change both together.
- **`cf d1` takes database UUIDs.** Names and binding names are rejected. `--local` without `--persist-to .cloudflare/state` writes to a directory the dev server never reads. Query the local database with `cf d1 raw <DATABASE_ID> --local --persist-to .cloudflare/state --sql "..."`.
- **Import PDFium as `@embedpdf/pdfium/pdfium.wasm?module`.** Workers cannot compile WebAssembly at runtime. The `?module` suffix makes both the Vite plugin and the Vitest plugin load a compiled module. Without it, the test runner treats the file as a WebAssembly ES module and fails on its `env` imports.
- **The workerd test project does not read `cloudflare.config.ts`.** It declares its compatibility date, flags, module rules, and any bindings in `vitest.config.ts`. Keep its compatibility date equal to the one in `cloudflare.config.ts`. Its `main` is `archive_coordinator.ts`, so tests reach a real `ARCHIVE_COORDINATOR`.
- **A message on the archive changes socket means only "read again".** `ArchiveCoordinator` stores nothing and sends one fixed text. A browser reads D1 after every message and every reconnection, so a reordered announcement changes nothing, and a lost one leaves a browser behind only until the next one or a reload. A tray row rechecks every 20 seconds as well. A write that other browsers should see calls `announceArchiveChange` after it commits. The upload itself does not, because the workflow's first step announces moments later. An email's workflow announces once it has printed the PDF.
- **The archive page does not repeat a text search on a change.** Its announcement listener skips `router.invalidate()` while `query` is set, because each repeat would be a billed AI Search query and a new document needs minutes to reach the index anyway.
- **A failed background reload replaces the page.** When a loader rejects during `router.invalidate()`, TanStack Router swaps the page for its error component, even though the old data was on screen. `defaultErrorComponent` in `src/router.tsx` is `PageLoadFailure`, which reloads on the next announcement. Without it, the framework's own error screen stays until a full page load.
- **`pnpm run deploy`, not `pnpm deploy`.** The second is a pnpm built-in.
- **`pnpm run provision` converges.** It finds each resource by name, applies pending migrations, and inserts missing household members without changing existing ones. It deploys only while the live Worker lacks a binding value from `parameterBindingValues` or the requested custom hostname, so ship code changes with `pnpm run deploy`. It touches only the Access policies and applications named `schublade <workerName>`, `schublade <workerName>: token ingestion`, and `schublade <workerName>: model context protocol`, and with `--email-address` it enables Email Routing on that address's zone. Enabling rewrites the zone's MX and SPF records, so the step stops and names the apex MX records Email Routing did not create; `--replace-mail-records`, which is not saved, lets it replace them. Apart from that consent, it never deletes.
- **knip exceptions.** knip ignores the IBM Plex packages, which the generator reads by file path, and `@types/emscripten`, which the `@embedpdf/pdfium` declarations reference. An export that a later phase will import carries a `/** @public */` tag. Remove the tag when the export gains a caller.
- **TypeScript stays on 6.0.** typescript-eslint supports TypeScript below 6.1, so `typescript` is pinned to `~6.0.3`.
- **Exact pins.** `cf` and `@cloudflare/vite-plugin` are open betas. They are pinned to exact versions that share one miniflare release. Upgrade them together in a deliberate commit.
- **`cf dev` ignores `.dev.vars` and `.env` for text bindings.** Override a text binding locally through its parameter in the git-ignored `schublade.deploy.json`, such as `classificationModel` or `aiGatewayIdentifier`. Point `aiGatewayIdentifier` at a gateway that exists on the account, such as `default`.
- **The local explorer API.** `cf dev` serves `/cdn-cgi/local/explorer/api` with raw D1 queries and Workflow instance status, steps, and output. `pnpm evaluate:extraction` reads it.
- **Node.js 24.22 or later.** `cf` requires it. `.node-version` pins the version for GitHub Actions.

## Commands

```bash
pnpm dev                        # predev applies local migrations, then cf dev on http://localhost:3000
pnpm check                      # typecheck, lint, format:check, knip, test, in sequence
pnpm typecheck                  # cf workers types, then tsc
pnpm test                       # Vitest, node and workerd projects
pnpm format                     # Prettier
pnpm database:generate          # drizzle-kit generate after a schema change
pnpm database:migrate:local     # apply migrations to the local database
pnpm generate:test-documents    # regenerate test_fixtures/documents
pnpm run provision              # create or reuse the environment, deploy behind Access; only when the user asks
pnpm evaluate:extraction        # billed: score classification against a running `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev`
pnpm evaluate:search            # billed: check fixed searches against a running `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev`
pnpm run build                  # cf build; needs schublade.deploy.json
pnpm run deploy                 # cf deploy; only when the user asks
```

`cf dev` and `cf build` forward only `--mode` to Vite. Set the port and other Vite options in `vite.config.ts`.

## Documentation lookup order

1. `cf docs search "<question>"` returns ranked documentation pages. Fetch a page with `Accept: text/markdown`.
2. `cf cli search "<task>"` finds a `cf` command. Run `<command> --help` for its flags and `cf schema <command>` for the API request it sends.
3. `https://developers.cloudflare.com/<product>/llms.txt` indexes a product, and appending `index.md` to a page URL returns it as Markdown.
4. The type declarations in `node_modules`, such as `cf/config` for the binding builders.

Keep `cf cli search` and `cf docs search` queries anonymous. Describe the action and the resource type, never names, identifiers, domains, or tokens.

## Skills

Load the skill that matches the task. Each has the exact steps.

| Skill                 | When to use                                         |
| --------------------- | --------------------------------------------------- |
| `new-database-table`  | Adding or changing a D1 table or column             |
| `add-binding`         | Adding a Cloudflare binding, variable, or secret    |

Skills live in `.agents/skills/`, and `.claude/skills` is a symbolic link to that folder.
