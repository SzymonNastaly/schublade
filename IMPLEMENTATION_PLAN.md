# Schublade implementation plan

This plan turns [VISION.md](VISION.md) into a build order. Each phase ends in a check you run against the `schublade-staging` Worker on the account's `workers.dev` subdomain behind Cloudflare Access. Do not start a phase until the check of the previous phase passes.

## Measured OCR prototype

A prototype Worker tested the OCR path from VISION.md on 2026-11-06, running in local `workerd` with a remote Workers AI binding. The input was a synthetic scanned German letter: one A4 page, image only, with slight rotation and noise.

| Measurement | Result |
| --- | --- |
| PDFium renders the page in `workerd` | Works with `nodejs_compat`. The `.wasm` file is imported as a compiled module and passed through Emscripten's `instantiateWasm` hook |
| Bundle size of PDFium, `fast-png`, and the handler | 4,849 KiB, 2,160 KiB compressed |
| Render time for one page at 150 dots per inch | 106 ms locally, producing a 1266 × 1774 grayscale PNG |
| Text layer detection | `FPDFText_CountChars` returns 0 for the scanned page, so PDFium also tells the workflow which pages need OCR |
| Moondream 3.1 transcription of the page | Every line correct, including the IBAN, the policy number, the amounts, and `ß`, `ä`, `ü` |
| Moondream latency and usage | 3.6 s, 760 input tokens, 241 output tokens |
| Moondream cost per page at $0.30 and $1.00 per million input and output tokens | About $0.0005 |

The prototype also established three constraints:

- `env.AI.run()` for Moondream returned a server-sent event stream even without `stream: true`. Each `chunk.answer` repeats the full text so far, so `text_recognizer.ts` keeps the last chunk. Request `task: "query"`, `reasoning: false`, and `temperature: 0`.
- Size is not a constraint. [Workers limits](https://developers.cloudflare.com/workers/platform/limits/) allow 64 MiB uncompressed on both plans and set no compressed limit, and PDFium adds 4.6 MiB.
- CPU time is the constraint. Workers Free allows 10 ms of CPU per invocation, and each Workflow step is subject to that limit. Rendering one page took 106 ms in the prototype, so scanned PDFs need Workers Paid, where the default CPU limit is 30 seconds. The prototype measured wall time, so the CPU figure is inferred.

### One Worker, not a dedicated OCR Worker

Schublade keeps PDFium in the single Worker. A second Worker would not help with either limit. The size limit is far away, and CPU limits come from the account plan, so a dedicated Worker has the same 10 ms limit on Workers Free. A split would add a second deployment, a service binding, and a second configuration for no gain.

The one cost that could justify a split is startup time. The runtime compiles the PDFium WebAssembly module when an isolate starts, and every isolate that serves the web interface pays for it. Staging deploys with PDFium bundled report a Worker startup time of 39 to 70 ms for a 7.8 MiB upload, or 2.8 MiB compressed. That startup time sits far below the 1 second limit, so PDFium stays in the single Worker.

## Quality tooling

The [coworkers](https://github.com/fayazara/coworkers) repository runs on the same stack: TanStack Start, `cf` with `cloudflare.config.ts`, and Cloudflare Access. Schublade adopts these practices from it:

1. **Agent guidance.** `AGENTS.md` holds a map from each subsystem to its files, a list of known pitfalls, ranked rules, and the documentation lookup order. `CLAUDE.md` contains only `@AGENTS.md`. Project skills live in `.agents/skills/`, and `.claude/skills` is a symbolic link to that folder. The first skills are `new-database-table` and `add-binding`.
2. **Binding types.** The `typecheck` script runs `cf workers types && tsc --noEmit`, so binding types never go stale. The generated `.cloudflare/types` folder is ignored by git.
3. **Migrations.** `drizzle-kit generate` writes the SQL, and `cf d1 migrations apply` applies it with `--persist-to .cloudflare/state`. A `predev` script migrates the local database. `drizzle-kit push` is never used.
4. **Exact pins for beta packages.** Pin `cf` and `@cloudflare/vite-plugin` to exact versions. Use `onlyBuiltDependencies` in `pnpm-workspace.yaml` to allow install scripts only for `esbuild` and `workerd`.
5. **Pure logic outside Durable Objects and Workflows.** Workflow steps and `ArchiveCoordinator` call pure modules through small port interfaces. Tests replace the ports with fakes.
6. **Errors as values.** Operations return `{ ok: false, code, error }` with a closed union of failure codes, and `executeOperation` maps each code to an HTTP status or an MCP error.
7. **Parsing at the boundary.** Every request body, email, and model output passes through Zod `safeParse`. Table inputs derive from the Drizzle schema with `drizzle-zod`.
8. **Deployment safety.** `previewUrls: false`, because preview hostnames are outside the Access application. `observability: { enabled: true }`. Server-side source maps are uploaded by `cf deploy`.
9. **Checks that name the fix.** A deployment fact learned the hard way becomes a check that throws with the fix in its message.

Schublade also closes the gaps that repository leaves open:

- **Fail closed.** The coworkers server treats every request as a demo user when the Access variables are blank. Schublade rejects every browser request when `ACCESS_TEAM_DOMAIN` or `ACCESS_AUD` is absent. For local development, `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev` skips the Access check and never reaches a production build. `pnpm dev` requires `cf auth login` because the Workers AI, Browser Run, and AI Search bindings run remotely in development without deploying. Set `aiGatewayIdentifier` in `schublade.deploy.json` to a gateway that exists on the account.
- **One gate, run before every push.** The coworkers repository has a lint configuration but nothing that runs it. In Schublade, `pnpm check` runs `typecheck`, `lint`, `format:check`, `knip`, and `test` in sequence. A `pre-push` git hook installed by `simple-git-hooks` runs `pnpm check`, so a failing change never reaches `main`.
- **Pinned toolchain.** `packageManager` in `package.json` and a `.node-version` file pin pnpm and Node.
- **Binding tests.** Vitest 5 runs two projects. Pure modules run in Node. Tests that touch D1, R2, Workflows, or Durable Objects run in `workerd` through `@cloudflare/vitest-plugin`, the renamed `@cloudflare/vitest-pool-workers`.

### Commits go straight to `main`

Schublade uses no pull requests. Each change is one commit pushed to `main` after `pnpm check` passes locally. A GitHub Actions workflow runs `pnpm check` once on each push to `main` as a safety net. It caches the pnpm store, cancels a run that a newer push supersedes, and skips pushes that change only Markdown files. Dependency upgrades are deliberate commits made with `pnpm update`, because a dependency bot works only through pull requests.

### Test budget

The test suite stays small and fast, so it costs almost nothing on GitHub Actions or Cloudflare.

- **Targets.** `pnpm check` finishes in under one minute on a laptop, and the GitHub Actions run finishes in under three minutes. With 46 tests at the end of phase 2, `pnpm check` takes about 12 seconds locally, and it took about 40 seconds on GitHub Actions at the end of phase 1. A test that pushes the suite past either target needs a reason in its commit message.
- **No Cloudflare usage in tests.** `@cloudflare/vitest-plugin` simulates D1, R2, Workflows, and Durable Objects locally in Miniflare, so tests make no billed requests. The Workers AI and AI Search bindings are replaced by recorded responses.
- **Few `workerd` tests.** The `workerd` project starts more slowly than the Node project, so it covers only the parts that need real bindings: the D1 queries with scope predicates, the workflow step sequence, and the `ArchiveCoordinator` broadcast. Everything else is a pure module tested in Node.
- **One test per behavior.** Tests assert literal expected values from `expected_extraction.json` or written into the test. Snapshot tests and browser end-to-end tests are not part of the suite. The interface is verified by hand on staging at the end of each phase.
- **Model and search evaluation stays manual.** `pnpm evaluate:extraction` calls the real Workers AI models against a local dev server and runs only when you start it, after a change to a prompt, a model, or the OCR path. `pnpm evaluate:search` runs fixed queries against a local dev server and the `schublade-development` AI Search instance on demand.

Lint and formatting use ESLint with `@tanstack/eslint-config` and Prettier with `prettier-plugin-tailwindcss`, matching the TanStack Start ecosystem. `knip` reports unused files, exports, and dependencies.

## Test documents

`test_fixtures/documents/` holds 12 synthetic, anonymous documents generated by `scripts/generate_test_documents.ts`. They cover every category, digital and scanned PDFs, a phone photo of a receipt, multi-page documents, an English invoice, and an email boilerplate attachment. `expected_extraction.json` records the literal values printed on each document. The fictional household has two adults and one child, and every person, company, address, and IBAN is invented. Regenerate the set with `pnpm generate:test-documents`. The generator is deterministic, so a regeneration that changes bytes shows up in review.

Tests assert against `expected_extraction.json`:

- **Deterministic tests** run in `pnpm check`. They cover text layer detection, page rendering, page counts, and the D1 and AI Search writes, with the Workers AI binding replaced by a recorded response.
- **The model evaluation** runs on demand with `pnpm evaluate:extraction` against a local dev server using the real, billed Workers AI binding. It reports, per document and per field, whether the extracted value matches. It is not part of `pnpm check`, because model output is not deterministic and every run costs money.

## Libraries

| Concern | Library |
| --- | --- |
| Application framework | TanStack Start, TanStack Router, TanStack Query |
| User interface | `@cloudflare/kumo`, `@phosphor-icons/react`, Tailwind CSS v4, `react-resizable-panels` |
| PDF display | `react-pdf` (pdf.js), because iOS Safari has historically rendered only the first page of a PDF in an `iframe` (verify in phase 1 before adding it) |
| PDF page rendering | `@embedpdf/pdfium`, `fast-png` |
| Relational storage | `drizzle-orm`, `drizzle-kit`, `drizzle-zod` |
| Validation | `zod` v4 |
| Inference | `ai` (Vercel AI SDK), `workers-ai-provider` |
| Access JWT verification | `jose` with `createRemoteJWKSet` against `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs` |
| Inbound mail parsing | `postal-mime` |
| Realtime state and MCP | `agents` (`Agent`, `useAgent`, `McpAgent`) |
| OAuth for `/mcp` | `@cloudflare/workers-oauth-provider` |
| HTML email to PDF | `@cloudflare/puppeteer` on Browser Run |
| Tests | Vitest 5, `@cloudflare/vitest-plugin` |
| Quality | ESLint, `@tanstack/eslint-config`, Prettier, `prettier-plugin-tailwindcss`, `knip`, `simple-git-hooks` |

## Build order

### Phase 0. Scaffold, quality gates, and authentication (complete)

1. Generate the project with `pnpm create cloudflare@latest --framework=tanstack-start` and merge it into the repository, keeping the existing `package.json` scripts.
2. Configure `cloudflare.config.ts` directly. There is no `cf migrate` step and no staging mode. You select an environment by the Worker name stored in the git-ignored `schublade.deploy.json`.
3. Add the quality tooling above: `AGENTS.md`, `CLAUDE.md`, the two Vitest 5 projects, ESLint, Prettier, `knip`, `pnpm check`, the `pre-push` hook, and the GitHub Actions workflow on pushes to `main`.
4. Define the Drizzle schema with all nine tables and apply the first migration to D1.
5. Add the Access JWT verification middleware in `src/server.ts`, failing closed.
6. Provision and seed with `pnpm run provision -- --worker-name <name> --access-email <email> --household-members <file.json>`. `--access-email` repeats, and the household file has the form `{"household_members": ["Display Name", ...]}`. The script requires `cf auth login` and Cloudflare Zero Trust enabled. It creates or reuses the D1 database `<worker>-database`, the R2 bucket `<worker>-documents`, an authenticated AI Gateway `<worker>`, and an AI Search instance `<worker>` with the custom metadata fields `person`, `sender`, `category`, and `document_date`. It then applies Drizzle migrations remotely, inserts the household members, deploys the Worker locked, creates the Cloudflare Access allow policy and a self-hosted Access application for the Worker's `workers.dev` hostname, and deploys again with Access enabled. It saves the answers in `schublade.deploy.json` so later runs need no flags, and code changes ship with `pnpm run deploy`.
7. Deploy `schublade-staging` to the account's `workers.dev` subdomain behind Access. `staging.schublade.org` is not used because that zone is not on the deploying account.

**Check.** The staging page lists the seeded household members. A request without an Access JWT returns 403. A deployment with blank Access variables returns 403 for every browser request. `pnpm check` passes in under one minute, and the GitHub Actions run on the first push to `main` passes.

**Verified.** `pnpm run provision` created the `schublade-staging` resources and Access application on `workers.dev`, and rerunning the script converged and reported existing resources as `already present`. `pnpm check` passed with 28 tests in about 11 seconds locally and in about 40 seconds on GitHub Actions.

### Phase 1. Ingestion core with OCR (complete)

1. The browser upload control accepts PDF, JPEG, PNG, and WebP files up to 25 MB per file and 50 MB per request. It detects each file type from the leading bytes, shows the rejection reason for any rejected file, writes accepted originals to R2, inserts a `documents` row with the status `processing`, and starts `DocumentIngestionWorkflow`.
2. `DocumentIngestionWorkflow` runs one step per unit: it extracts text with `toMarkdown()` and checks for a text layer with PDFium, renders each page without a text layer at 150 dpi with PDFium WebAssembly and transcribes it with `@cf/moondream/moondream3.1-9B-A2B` in its own step, and stores the Markdown in R2 at `documents/<id>/content.md`.
3. The workflow reads the taxonomy and household members from D1 and classifies the document through AI Gateway with `workers-ai-provider` and the Vercel AI SDK `generateText` with `Output.object`, because `generateObject` is deprecated. The default model is `@cf/deepseek-ai/deepseek-v4.1-flash-1017`, which `classificationModel` in `schublade.deploy.json` can override per deployment. The classifier sets `person` to the member the document concerns, such as the child who is the patient on a dental invoice addressed to a parent, or to `household` when the document concerns several members or the whole household. The `documents` table holds one verification reason, and an illegible required field takes precedence when a new taxonomy record also applies. One D1 batch archives the document and writes only while the document is still in the `classifying` status.
4. The archive page lists documents, refreshes by polling while any document is processing, and shows each original file and its Markdown.
5. Add `pnpm evaluate:extraction` and run it over `test_fixtures/documents/`.
6. Measure cold-start latency of the Worker on staging with PDFium in the bundle, as recorded in [One Worker, not a dedicated OCR Worker](#one-worker-not-a-dedicated-ocr-worker).

**Check.** Every test document reaches `archived`. The evaluation report shows the category, sender, person, document date, and amount correct for every document, and the result and the cold-start measurement are recorded in this file.

**Verified.** On `schublade-staging`, a scanned dental invoice was stored in R2 and its workflow instance was started through the `cf` command-line interface, because a browser upload on staging needs the household member's Access sign-in. The document archived in about 20 seconds with every expected field correct: sender, category `Medical`, person set to the patient, document date, amount `91.84 EUR`, due date, IBAN, and invoice number. A signed-in browser upload on staging is still to be verified. Across the 12 synthetic test documents, `pnpm evaluate:extraction` against a local dev server cost 0.175 USD in total, at about 0.0023 USD per DeepSeek classification and 0.0008 USD per uncached Moondream page.

| Model | Correct fields | Notes |
| --- | --- | --- |
| `@cf/deepseek-ai/deepseek-v4.1-flash-1017` | 80 of 80 | The first run scored 79 of 80 because the supermarket receipt fixture expected `Frischemarkt Talbrück` while the receipt prints the legal name `Frischemarkt Talbrück GmbH`. After the fixture correction and the narrower euro-sign repair, `pnpm evaluate:extraction` scored 80 of 80 fields on all 12 documents. The rerun took 55 seconds of wall time for the batch and cost 0.036 USD. |
| `gpt-oss-120b` | 74 of 80 | The model completed all 12 documents in the run before the fixture correction, with no later rerun. |
| `Gemma 4 26B` | 70 of 80 | One document failed in the run before the fixture correction, with no later rerun. |

OCR findings from the phase 1 evaluation:

- **Euro sign restoration.** The Moondream service returns 3-byte UTF-8 characters such as the euro sign as `U+FFFD`, while `ä`, `ß`, and `ś` survive. Schublade restores `€` only directly beside a two-decimal amount and tells the classifier that any remaining `U+FFFD` marks an unreadable character.
- **Thermal receipt photo.** Moondream read the total, date, and receipt number accurately, along with 7 of 10 item prices. Splitting the image into halves lowered accuracy to 0 of 10 item prices.
- **Scanned hardware-store receipt.** Rendering at 200 dpi read 6 of 6 item lines compared to 5 of 6 at 150 dpi on one sample. Schublade keeps 150 dpi.

### Phase 2. Search (complete)

1. The last workflow step, `index document`, uploads one AI Search item named `<documentId>.md`. Its content leads with the title, sender, tags, and summary, followed by the full Markdown. The item carries four custom metadata fields: `person` holds the household member identifier or `household`, `sender` holds the sender identifier, `category` holds the category identifier, and `document_date` holds an ISO 8601 datetime such as `2026-09-22T00:00:00Z` because Unix seconds do not filter. Uploading under an existing name replaces the item, so the step is safe to retry.
2. `POST /api/search_index` indexes archived documents that the index lacks or failed to index, at most 100 per call, and reports `failedDocuments` with a reason for each instead of stopping. A Cron Trigger runs the same backfill every 15 minutes on the `*/15 * * * *` schedule, so documents archived before phase 2 and documents whose index step failed get indexed without a signed-in request. The backfill pages through the index until an empty page and stops after 100 pages, or 5,000 items. Local development binds `SEARCH_INDEX` to a separate remote AI Search instance named `schublade-development`, so local runs never write into a deployment's index. `pnpm run provision` does not create that instance. Create it once with `cf ai-search create schublade-development` and the same four custom metadata fields: `person`, `sender`, and `category` as text, and `document_date` as datetime.
3. A text query runs a hybrid AI Search query with the `person`, `sender`, `category`, and date range filters, always requests the maximum of 50 chunks, groups chunks by document, and shows each document's best passage. D1 then reapplies every filter and applies the tag and amount filters, so a stale index item can only drop a result and never show a wrong one. The similarity cache is turned off per search so new documents are found. Without a text query, filtering is a plain D1 query.
4. The archive page adds a search input focused with `/`, `Cmd+K`, or `Ctrl+K`, and facets for person, sender, category, tag, date range, and amount. The person facet hides when the household has one member, and on phones the facets fold behind a filter button. Search state lives in the URL so a search can be shared as a link, and each parameter is parsed on its own so one bad parameter does not discard the rest. Below the `md` breakpoint, the document list becomes one stacked row per document with the title, then the sender, date, person, and amount, with no horizontal scrolling at 375 px. Desktop widths keep the table. The layout uses CSS breakpoints, not a `useMobileViewport()` hook.
5. The Worker entry in `src/server.ts` refuses every write request, which is any method other than `GET`, `HEAD`, or `OPTIONS`, with 403 when its `Origin` header names another site, because the browser sends the Access session cookie with cross-site requests. Requests without an `Origin` header, such as scripts and token-authenticated callers, pass. An upload without a multipart body gets 400.
6. Add `pnpm evaluate:search` to run fixed queries against a local `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev` server and the `schublade-development` index.

**Check.** An English query finds a German invoice. An exact IBAN string finds its document. Filtering a search to one member returns every matching document of that member, not a subset of the unfiltered top results.

**Verified.** `pnpm evaluate:search` passed 8 of 8 checks against a local `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev` server and the `schublade-development` index:

- `"electricity bill"` returns the German electricity invoice first.
- The printed IBAN of the dental invoice returns that invoice first.
- A person filter for Jonas Becker with a text query returns only his 3 documents.
- A person filter for Jonas Becker without a text query returns only his 3 documents.
- Category `Invoice` with `"Nordkabel"` ranks the telecom invoice first and returns only invoices.
- `"Nordkabel"` without the category filter also returns the general terms.
- `"Talbrück"` with a September 2026 date range returns only the 2 documents dated in that month.
- An amount range of 70 to 100 returns only the 3 matching documents.

Measured through the local dev server, which adds a hop to the remote binding, text queries took 0.5 to 2.4 seconds with a median of about 1.7 seconds, and D1-only filtering took about 10 ms. Indexing 12 documents uploaded together took 73 to 145 seconds per item from upload to indexed, with a median of 104 seconds. After the deploy to `schublade-staging`, the 11:30 UTC run of the scheduled backfill uploaded the 3 documents archived on staging before phase 2, and all 3 were indexed by 11:32 UTC. A query for the dental invoice's IBAN on the staging index returned that document as the only result. The signed-in search page on staging has not been tried yet.

### Phase 3. Tokens and inbound mail

1. Add API token issuance and the `/api/documents/ingest` endpoint.
2. Add the `email()` handler with `postal-mime` and the sender allowlist.
3. Add the Access bypass rule for `/api/documents/ingest`.

**Check.** A QuickScan Shortcut upload and a forwarded invoice email both archive. The general terms attachment receives the non-archival verification reason.

### Phase 4. Pending verification

Add the three verification reasons, the **Pending verification** view, and the confirm, rename, and merge operations for senders, categories, and tags.

**Check.** A document from a new sender appears in the view, and merging the sender into an existing record updates every affected document in D1 and in AI Search.

### Phase 5. Realtime state

Replace the polling from phase 1 with `ArchiveCoordinator` on the `agents` SDK.

**Check.** Uploading in one browser shows the progress row in a second browser without a reload.

### Phase 6. MCP

Add `/mcp` with `McpAgent` and `@cloudflare/workers-oauth-provider`, with the consent screen behind Access. Add the Access bypass rule for `/mcp` and the OAuth endpoints.

**Check.** Claude connects with a grant restricted to `allowedCategories: ["Invoice"]` and cannot read any other category through search or listing.

### Phase 7. HTML email and mobile

1. Render body-only HTML emails to PDF on Browser Run.
2. Add the Web App Manifest, the mobile bottom action bar, and the `Drawer` layout.

**Check.** A forwarded App Store receipt archives as a PDF. The installed home screen application uploads from the camera.

## Follow-ups

- **Very large documents.** The workflow refuses a document with more than 50 pages without a text layer before it transcribes any page. The limit caps OCR cost per document at about 0.04 USD, and the refused document ends with the status `failed`. A workflow step output over about 1 MiB of Markdown still fails the step, and the workflow does not truncate classifier input.
- **OCR resolution and receipt item lines.** Choosing whether to render scanned pages at 200 dpi instead of 150 dpi and improving item-line transcription on thermal receipts remain open.
- **Tag and amount filters on text searches.** AI Search returns at most 50 chunks per query, and D1 applies the tag and amount filters to the documents in those chunks. A text query combined with a tag or amount filter therefore sees only documents among the top 50 chunks.
- **Re-uploading index items after metadata edits.** AI Search filters on the `person`, `sender`, `category`, and `document_date` fields stored on each index item. When phase 4 lets members edit a document's person, sender, category, or date, the index item must be uploaded again.
- **The 5,000-item backfill limit.** The backfill pages through AI Search until an empty page and stops after 100 pages, or 5,000 items. An index above 5,000 items makes the backfill fail by design.
