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
11. **Do not edit the human-facing documents.** README.md, VISION.md, and IMPLEMENTATION_PLAN.md are written outside coding sessions. List the changes they need in your report instead.

## Repository layout

```text
src/
	server.ts                              Worker entry: Access verification, then TanStack Start; exports the Workflow and Durable Object classes
	ambient_declarations.d.ts              Types for import.meta.env, the PDFium WebAssembly import, and PDF fixture imports
	authentication/
		access_verification.ts               requireAccess: Cloudflare Access assertion verification with jose
		access_verification.test.ts
	database/
		schema.ts                            The nine Drizzle tables and their drizzle-zod insert schemas
		client.ts                            Drizzle bound to env.DATABASE, and connectDatabase for a passed binding
	archive/
		document_listing.ts                  The document listing query shared by the server function and the API route
	ingestion/                             Ingestion domain; all but document_ingestion.ts and document_upload.ts are pure and tested in Node
		document_lifecycle.ts                Document status transition table
		source_file.ts                       Accepted file kinds and R2 object keys
		document_text.ts                     Text layer detection threshold and Markdown assembly
		document_classification.ts           Extracted field set, standard categories, output schema, and normalization
		classification_prompt.ts             Classification prompt with the taxonomy, the members, and the schema
		taxonomy_resolution.ts               Name normalization and matching against sender, category, and tag rows
		verification_assessment.ts           Verification reason of an archived document
		document_ingestion.ts                The workflow steps and their D1 and R2 writes
		document_ingestion.workerd.test.ts   Step order with recorded Workers AI responses
		document_upload.ts                   R2 write, documents row, and workflow start for one uploaded file
	utilities/
		server_functions.ts                  TanStack Start server functions
	routes/
		__root.tsx                           HTML document shell
		index.tsx                            Archive page: document table, upload control, and inspection pane
		api/documents.ts                     GET lists documents, POST accepts multipart uploads in fields named files
		api/documents.$documentId.$representation.ts   GET the original file or the extracted Markdown
	router.tsx                             Router factory
	routeTree.gen.ts                       Generated by `pnpm dev` and `pnpm build`; do not edit
	styles.css                             Tailwind CSS v4 and Kumo styles
	workflows/
		document_ingestion_workflow.ts       DocumentIngestionWorkflow, which passes its env to ingestDocument
	durable_objects/
		archive_coordinator.ts               ArchiveCoordinator stub, implemented in phase 5
	inference/
		page_rasterizer.ts                   PDFium WebAssembly: text layer detection and page rendering to PNG
		page_rasterizer.workerd.test.ts
		text_recognizer.ts                   Moondream page transcription, event stream parsing, and euro sign repair
		text_recognizer.test.ts
		document_classifier.ts               generateText with workers-ai-provider through AI Gateway
drizzle/                                 Generated SQL migrations and drizzle-kit snapshots
scripts/
	provision_environment.ts               `pnpm run provision`: creates or reuses the resources, deploys behind Access
	generate_test_documents.ts             Deterministic generator for test_fixtures/documents
	evaluate_extraction.ts                 `pnpm evaluate:extraction`: uploads the test documents to a dev server and scores the results
	test_document_generation/              Document catalog, page layout, and scan and photograph simulation
test_fixtures/
	documents/                             Synthetic test documents and expected_extraction.json
	inference_recordings/                  Workers AI responses recorded from the test documents for workerd tests
.agents/skills/                          Project skills; .claude/skills links here
.github/workflows/check.yml              Runs `pnpm check` on each push to main
cloudflare.config.ts                     Worker, bindings, Workflow and Durable Object exports, and the deployment guard
drizzle.config.ts                        drizzle-kit configuration
vite.config.ts                           Vite plugins, dev server port, Worker source maps
vitest.config.ts                         The node and workerd test projects
eslint.config.js, .prettierrc.json, knip.json, tsconfig.json
```

## Things that will bite you

- **Configuration modes.** Builds evaluate `cloudflare.config.ts` in `production` mode or the `--mode` they receive. `cf dev` evaluates it in `development` mode, and `cf workers types` evaluates it without a mode. Only build modes require the identifiers in `schublade.deploy.json`.
- **AI Search has no local simulation.** In development mode without a provisioned instance, `SEARCH_INDEX` is absent, so the `Env` type marks it optional. Check for it at the one place that uses it.
- **`cf dev` needs a Cloudflare login.** `AI_RUNTIME` and `BROWSER_RENDERER` are remote in development, so `cf dev` opens a remote preview session on the signed-in account. It deploys nothing.
- **Local development returns 403.** The Access variables are blank locally, so `GET /` returns `Access denied: access_unconfigured`. Start the dev server with `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev` to see the interface.
- **One local database identifier.** Local development simulates D1 under `00000000-0000-4000-8000-000000000000`. The constant lives in `cloudflare.config.ts` and in the `database:migrate:local` script. Change both together.
- **`cf d1` takes database UUIDs.** Names and binding names are rejected. `--local` without `--persist-to .cloudflare/state` writes to a directory the dev server never reads. Query the local database with `cf d1 raw <DATABASE_ID> --local --persist-to .cloudflare/state --sql "..."`.
- **Import PDFium as `@embedpdf/pdfium/pdfium.wasm?module`.** Workers cannot compile WebAssembly at runtime. The `?module` suffix makes both the Vite plugin and the Vitest plugin load a compiled module. Without it, the test runner treats the file as a WebAssembly ES module and fails on its `env` imports.
- **The workerd test project does not read `cloudflare.config.ts`.** It declares its compatibility date, flags, module rules, and any bindings in `vitest.config.ts`. Keep its compatibility date equal to the one in `cloudflare.config.ts`.
- **`pnpm run deploy`, not `pnpm deploy`.** The second is a pnpm built-in.
- **`pnpm run provision` converges.** It finds each resource by name, applies pending migrations, and inserts missing household members without changing existing ones. It deploys only while the live Worker lacks the current Access values, so ship code changes with `pnpm run deploy`. It touches only the Access policy and application named `schublade <workerName>`.
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
