# Schublade implementation plan

This plan turns [VISION.md](VISION.md) into a build order. Each phase ends in a check you run against the `schublade-staging` Worker at `https://staging.schublade.org` behind Cloudflare Access. Do not start a phase until the check of the previous phase passes.

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
6. **Errors and upload outcomes.** Server functions throw an `Error` whose message names the cause, such as `This action requires the modify permission`. Uploads return one outcome per file: `accepted`, `rejected` with a reason, or `failed` with a reason.
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

- **Targets.** `pnpm check` finishes in under one minute on a laptop, and the GitHub Actions run finishes in under three minutes. With 122 tests after the interface revision, `pnpm check` takes about 22 seconds locally, and the GitHub Actions run took 70 to 79 seconds on the last three pushes to `main`. A test that pushes the suite past either target needs a reason in its commit message.
- **No Cloudflare usage in tests.** `@cloudflare/vitest-plugin` simulates D1, R2, Workflows, and Durable Objects locally in Miniflare, so tests make no billed requests. The Workers AI and AI Search bindings are replaced by recorded responses.
- **Few `workerd` tests.** Because the `workerd` project starts more slowly than the Node project, it covers only the parts that need real bindings. The `workerd` tests cover the D1, R2, and AI Search queries of the archive, ingestion, and search modules. They also cover the workflow step sequence, the upload and inbound mail handlers, PDFium page rendering, request dispatch, the database migrations, and each server function's permission level. Scope predicates and `ArchiveCoordinator` do not exist yet. Everything else is a pure module tested in Node.
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
| User interface | `@cloudflare/kumo`, `@phosphor-icons/react`, Tailwind CSS v4 |
| PDF display | `pdfjs-dist` 6.5.438, legacy build, because the standard build hung while drawing in iOS Safari and an `iframe` there draws a PDF at natural width |
| PDF page rendering | `@embedpdf/pdfium`, `fast-png` |
| Relational storage | `drizzle-orm`, `drizzle-kit`, `drizzle-zod` |
| Validation | `zod` v4 |
| Inference | `ai` (Vercel AI SDK), `workers-ai-provider` |
| Access JWT verification | `jose` with `createRemoteJWKSet` against `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs` |
| Inbound mail parsing | `postal-mime` |
| Realtime state and MCP | `agents` (`Agent`, `useAgent`, `McpAgent`), planned for phases 5 and 6 |
| OAuth for `/mcp` | `@cloudflare/workers-oauth-provider`, planned for phase 6 |
| HTML email to PDF | `@cloudflare/puppeteer` on Browser Run, planned for phase 7 |
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
7. Deploy `schublade-staging` to the account's `workers.dev` subdomain behind Access. Phase 3 later moved it to `https://staging.schublade.org`.

**Check.** The staging page lists the seeded household members. A request without an Access JWT returns 403. A deployment with blank Access variables returns 403 for every browser request. `pnpm check` passes in under one minute, and the GitHub Actions run on the first push to `main` passes.

**Verified.** `pnpm run provision` created the `schublade-staging` resources and Access application on `workers.dev`, and rerunning the script converged and reported existing resources as `already present`. `pnpm check` passed with 28 tests in about 11 seconds locally and in about 40 seconds on GitHub Actions.

### Phase 1. Ingestion core with OCR (complete)

1. The browser upload control accepts at most 20 PDF, JPEG, PNG, and WebP files per request, up to 25 MB per file and 50 MB per request. It detects each file type from the leading bytes, shows the rejection reason for any rejected file, writes accepted originals to R2, inserts a `documents` row with the status `processing`, and starts `DocumentIngestionWorkflow`.
2. `DocumentIngestionWorkflow` runs one step per unit. For each PDF page, it selects a text source in three tiers: first the page's `toMarkdown()` section when that section has at least 40 letters or digits, second PDFium's text extraction for the page when that text has at least 40 letters or digits and fewer than one replacement character per ten of them, and third a 150 dpi PNG rendered with PDFium WebAssembly and transcribed by `@cf/moondream/moondream3.1-9B-A2B` in its own step. Image files always go to Moondream, and the 50-page limit applies only to pages that need Moondream. The workflow stores the assembled Markdown in R2 at `documents/<id>/content.md`.
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

OCR and text-pipeline findings from phase 1 and phase 3:

- **Euro sign restoration.** The Moondream service returns 3-byte UTF-8 characters such as the euro sign as `U+FFFD`, while `ä`, `ß`, and `ś` survive. Schublade restores `€` only directly beside a two-decimal amount and tells the classifier that any remaining `U+FFFD` marks an unreadable character.
- **Thermal receipt photo.** Moondream read the total, date, and receipt number accurately, along with 7 of 10 item prices. Splitting the image into halves lowered accuracy to 0 of 10 item prices.
- **Scanned hardware-store receipt.** Rendering at 200 dpi read 6 of 6 item lines compared to 5 of 6 at 150 dpi on one sample. Schublade keeps 150 dpi.
- **Three-tier PDF page text pipeline.** Workers AI `toMarkdown()` returns empty page sections for tagged PDFs whose structure tree it cannot follow. A real emailed train ticket generated by Apache FOP as a tagged PDF 1.5 file returned only the metadata block from `toMarkdown()`. The same file with its structure tree removed converted in full, and `pdftotext` read 2,370 letters and digits from the original file. With PDFium text extraction as the second tier before Moondream, that ticket classified with the expected sender, category, title, and date without a Moondream call. `pnpm evaluate:extraction` still scores 80 of 80 across the 12 test documents with 9 Moondream calls, all on the scans and the receipt photograph.

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

### Phase 3. Tokens and inbound mail (complete)

1. Resolve every request to one of three callers: `member_session` from a verified Access assertion, `api_token` with its authorization scope, or `inbound_mail` with the sender address. One pure function checks permissions against the ordered levels `read < ingest < modify < administer`.
2. Add API token management on the **Settings** page, which requires the `administer` level that a signed-in member holds. Members issue tokens with the `ingest` level. Each token is `schublade_` followed by 43 random base64url characters, or 256 bits, and the page shows the token once. D1 stores only the SHA-256 digest, revoking a token deletes its row, and bearer authentication writes the last-used timestamp at most once per hour.
3. Add `POST /api/documents/ingest` and its Access bypass application. The endpoint accepts the same multipart `files` field as the browser upload with an `Authorization: Bearer <token>` header and no Access sign-in. Both uploads and inbound messages accept at most 20 files, 25 MB per file, and 50 MB per request, detect file types from their content, and refuse cross-site writes. The Worker skips Access only for the exact pathname `/api/documents/ingest`, and an Access bypass application covers that path at the edge. A missing or unknown token returns 401, `GET` returns 405, and any subpath returns 403. For example, `curl -X POST -H "Authorization: Bearer <token>" -F "files=@invoice.pdf;type=application/pdf" https://<host>/api/documents/ingest` returns JSON outcomes per file such as `{"kind":"accepted",...}`.
4. Add the `email()` handler with `postal-mime` for the configured ingestion address, `documents@schublade.org` on staging. The handler checks the envelope recipient and sender before it parses the message. It admits a message only when the recipient is the ingestion address, the envelope sender and the single `From` address match the same allowlisted address from the Access email list, and Cloudflare's DMARC result passes. The handler trusts `Authentication-Results` from Cloudflare only inside the header block that Email Routing prepends, which runs from its own `Received` header to the next `Received` header. `gmail.com` publishes a DMARC policy of `none`, so without the DMARC check Email Routing would deliver spoofed `gmail.com` senders. PDF and image attachments enter ingestion with the email subject, sender, and plain-text body as classification context, while inline images under 15 KB are skipped. A message without a usable attachment is stored with the status `awaiting_rendering` for phase 7 HTML-to-PDF rendering, and redelivery of the same message adds nothing.

To upload from QuickScan or another iOS application through an Apple Shortcut:

1. Open **Settings**, issue a token with the **Ingest documents** permission, and copy the token while it is shown.
2. Create an Apple Shortcut that receives PDFs from the Share Sheet.
3. Add **Repeat with Each** over **Shortcut Input**.
4. Inside the loop, add **Get Contents of URL** for `https://<host>/api/documents/ingest` with method `POST`, the header `Authorization: Bearer <token>`, and a **Form** request body that has a **File** field named `files` set to **Repeat Item**.
5. Show the result, then share a scan to the Shortcut.

**Check.** A QuickScan Shortcut upload and a forwarded invoice email both archive. The general terms attachment receives the non-archival verification reason.

**Verified.** On 2026-11-06 the `schublade.org` zone moved to the account, and its two Porkbun parking `CNAME` records were deleted so Email Routing could own the apex `MX` and `TXT` records. Running `pnpm run provision --hostname staging.schublade.org --email-address documents@schublade.org` moved `schublade-staging` to `https://staging.schublade.org` behind Cloudflare Access. The script extended the Access application to the custom hostname before the deployment moved the route, then narrowed the Access application to `staging.schublade.org`. The `workers.dev` hostname is now switched off and returns 404. On staging, an invoice uploaded to `POST /api/documents/ingest` with a bearer token archived with every expected field, and the token stopped working after revocation. A real email from an allowlisted `gmail.com` address with a PDF attachment was admitted with `dmarc=pass` and archived. On that delivery, the header block that Email Routing prepended above the sender's `Received` header had the order `Received`, `ARC-Seal`, `ARC-Message-Signature`, `ARC-Authentication-Results`, `Received-SPF`, `Authentication-Results`, and `X-CF-SpamH-Score`. The Apple Shortcut steps above were not run, and the `non_archival_attachment` verification reason is tracked in [Follow-ups](#follow-ups).

### Phase 4. Pending verification (complete)

1. Senders, categories, and tags carry a `confirmed_at` timestamp. Records that the classifier creates start unconfirmed. Standard categories, confirmed records, and records that a member creates or names in an edit are confirmed.
2. The **Pending verification** navigation entry shows a count badge, and the view lists three kinds of items. An unconfirmed taxonomy record appears with every document that refers to it. A document with an `illegible_required_field` reason appears with its missing fields, and a document with a `non_archival_attachment` reason appears as a non-archival attachment. New taxonomy records come from the unconfirmed rows rather than a per-document reason, so confirming one record resolves all of its documents. The queries for the view use joins instead of identifier lists, because D1 allows at most 100 bound parameters per query. The interface revision below adds a fourth kind for failed documents.
3. The classifier marks boilerplate such as general terms, privacy notices, and advertising as non-archival. A document stores at most one of the two document reasons, and `non_archival_attachment` takes precedence over `illegible_required_field` because that file is meant to be deleted.
4. For a taxonomy record, a member can confirm it, rename it, merge it into another record, or delete it while it is unused and unconfirmed. For a document, a member can supply a missing field, keep a non-archival attachment, or delete the document. A rename onto an existing name proposes a merge. A merge moves every document and tag link in one D1 batch, deletes the source record, and does nothing if the source no longer exists. When a category merge moves documents into another category, the batch also re-checks their required fields. Deleting a document removes its stored files, rows, tag links, extracted fields, and search item. Every destructive action and every merge asks for confirmation in a dialog that states what will happen, such as how many documents move. The document page has an edit form for title, document date, sender, category, person, tags, and extracted fields.
5. One table assigns each operation its permission level. Editing a document and supplying fields require `modify`, and merging and deleting require `administer`. Every signed-in member holds `administer`.
6. Each document records the revision that was last indexed in `indexed_at`. A single-document edit re-uploads its search item in the same request. Merges and renames mark the moved documents stale, and the 15-minute scheduled backfill re-uploads stale documents along with missing and failed ones. If a document changes while its item uploads, the upload is not counted as current, so the backfill uploads the document again.
7. Every document has its own page at `/documents/<id>`, which requires the `read` permission level. After a member deletes a document on its page, the browser returns to the previous page, or to the archive when there is no previous page. The address of a deleted or unknown document shows "This document does not exist". The interface revision below describes the page as it is now.

**Check.** A document from a new sender appears in the view, and merging the sender into an existing record updates every affected document in D1 and in AI Search.

**Verified.** Phase 4 is deployed to `https://staging.schublade.org`. Migrations `0001` and `0002` applied on staging. Standard categories became confirmed, classifier-created senders and categories stayed unconfirmed, the stored `new_taxonomy_record` reasons were cleared, and every archived document received an `indexed_at` timestamp. On staging, a household member signed in through Cloudflare Access on a phone and opened **Pending verification**, which listed 6 entries. The actions in that view were not tried on staging. Locally, after merging one sender into another, the `schublade-development` index held no item under the old sender, and a search filtered by that sender returned nothing. Deleting a document left no stored files, rows, or search item. The view queries were tested with 150 documents on one tag and 120 unconfirmed records. Tests also prove that each server function enforces its permission level through the real request path. At a 375 px phone width locally, a link in **Pending verification** opened the right document, and the PDF preview rendered. After a test deletion on the document page, the browser returned to **Pending verification** with one document fewer in the entry, and the deleted document's address showed the not-found page. `pnpm evaluate:extraction` now scores 92 fields across the 12 test documents, including the non-archival flag. The non-archival flag scored 12 of 12 correct, with only the general terms flagged. The latest runs scored 91 of 92, with one varying miss each time. One run missed the receipt number, and another missed the telecom sender, which came back as an existing shorter sender name in the local archive. At the end of phase 4, `pnpm check` ran 89 tests in about 17 seconds.

### Interface revision after phase 4 (complete)

A local Paperless-ngx 3.4.2 install with the same 12 synthetic documents showed where Schublade's screens fell short. The revision took what fits an archive that files documents automatically and left out the rest. It replaces the inspection pane, the document page layout, the card list in **Pending verification**, and the filter layout that phases 1, 2, and 4 describe.

1. Every row in the document list links to `/documents/<id>`, and the inspection pane below the list is gone. The list sorts by document date, newest first. A document without a date stays on top, because it is still processing or needs a date supplied. A status badge appears only while a document is unfinished.
2. The document page reads title, summary, document on every screen size. `pdfjs-dist` draws each PDF page fitted to one A4-sized box, and only the visible page and its neighbours hold a canvas. Below `md`, pages swipe sideways. From `md` upward, pages scroll inside the box beside the details.
3. The details read as plain text, and **Edit details** opens the form. The form offers only the extracted fields that the category uses or that hold a value, and **Delete document** appears only there. Sender, category, person, and tag values link to the filtered archive.
4. `/verification` is an overview, and `/verification/review` shows one entry at a time beside its document. **Confirm new senders** confirms the ticked senders in one call and leaves out a sender named `Unknown`. `confirmTaxonomyRecords` splits its identifiers into chunks because D1 allows at most 100 bound parameters per query.
5. A tray follows each browser upload through processing and stays open across pages. Migration `0003` adds `documents.failure_reason`, which holds `unreadable_file`, `page_limit_exceeded`, or `processing_error`. Members can retry a failed document, which appears in **Pending verification** as `failed_ingestion` and counts toward the badge. Retry sets the status back to `processing` only while it is still `failed`, so a double click starts one run. The workflow opens each PDF with PDFium before it calls `toMarkdown`, so a file that PDFium cannot open fails early.
6. `useDocumentStatusUpdates` is the one place that reads document status. It polls `retrieveDocumentStatuses` every 2 seconds, and the tray and the archive page both use it.
7. Every row in the document list and in the **Pending verification** overview starts with a picture of the first page. The Worker renders it at 40 dpi the first time someone requests it and stores it at `documents/<id>/thumbnail.png`, so existing documents need no backfill and ingestion gains no step. An image original is served as its own thumbnail.
8. The filters are one row of **Person**, **Sender**, **Category**, **Date**, and **More**, with a document count per value and active filters as removable chips. Below `md`, the filter button unfolds the same controls. Form fields below `md` use 16 px text, because iOS Safari zooms the page when a focused field holds smaller text.

**Verified.** The revision is deployed to `https://staging.schublade.org` as version `29d8345e`, with migration `0003` applied on 2026-11-08. A multi-page document looks right on a real iPhone. In iOS 26.5 Safari on the simulator, an `iframe` cut off the right side of the page, and a fit-to-width setting in the address changed nothing. PDF.js fit all three pages of the rental contract with no sideways scrolling. With pages scrolling up and down inside the box, a swipe moved the document 465 px and the page 0 px. With sideways paging, a horizontal swipe turned the page and a vertical swipe scrolled the page. Locally at phone and desktop widths, a corrupt PDF failed with its reason, its tray row survived navigation, and it could be retried and deleted. A real upload went from **Uploading** to archived with an **Open** link in about 6 seconds. `pnpm check` runs 122 tests in about 22 seconds.

### Phase 5. Realtime state

Replace the 2-second polling inside `useDocumentStatusUpdates` with `ArchiveCoordinator` on the `agents` SDK. Nothing else in the interface knows how updates arrive.

**Check.** Uploading in one browser shows the progress row in a second browser without a reload.

### Phase 6. MCP

Add `/mcp` with `McpAgent` and `@cloudflare/workers-oauth-provider`, with the consent screen behind Access. Add the Access bypass rule for `/mcp` and the OAuth endpoints.

**Check.** Claude connects with a grant restricted to `allowedCategories: ["Invoice"]` and cannot read any other category through search or listing.

### Phase 7. HTML email and mobile

1. Render body-only HTML emails to PDF on Browser Run.
2. Add the Web App Manifest and the mobile bottom action bar.

**Check.** A forwarded App Store receipt archives as a PDF. The installed home screen application uploads from the camera.

## Follow-ups

- **Very large documents.** The workflow refuses a document when more than 50 pages need Moondream before it transcribes any page. The limit caps OCR cost per document at about 0.04 USD, and the refused document ends with the status `failed` and the reason `page_limit_exceeded`. A workflow step output over about 1 MiB of Markdown still fails the step, and the workflow does not truncate classifier input.
- **OCR resolution and receipt item lines.** Choosing whether to render scanned pages at 200 dpi instead of 150 dpi and improving item-line transcription on thermal receipts remain open.
- **PDF glyphs without Unicode mappings.** When PDFium extracts text from a PDF page in the second tier of the text pipeline, a glyph without a Unicode mapping can come out as a wrong letter that the replacement-character threshold cannot detect. `FPDFText_HasUnicodeMapError` could catch those pages and has not been tested yet.
- **Tag and amount filters on text searches.** AI Search returns at most 50 chunks per query, and D1 applies the tag and amount filters to the documents in those chunks. A text query combined with a tag or amount filter therefore sees only documents among the top 50 chunks.
- **The 5,000-item backfill limit.** The backfill pages through AI Search until an empty page and stops after 100 pages, or 5,000 items. An index above 5,000 items makes the backfill fail by design.
- **Rate limit on the token ingestion endpoint.** `POST /api/documents/ingest` has no rate limit yet.
- **Concurrent edit during a category merge.** A category merge reads the moved documents right before its batch runs, so an edit that lands in between can be reassessed from older fields.
- **Concurrent deletion in AI Search.** Deleting an item that AI Search already removed can report an error on one of two concurrent deletions, and a rerun converges.
- **Invented sender on unreadable documents.** The classification output schema requires a sender name. When a document has no readable text, the classifier invents a sender such as `Unknown` and a title such as `Unknown Document`. The invented sender appears in **Pending verification** as a new sender record. A confirmed record no longer appears there. If you confirm that new record, later unreadable documents that the classifier files under that sender do not appear in **Pending verification** for review. Delete or merge the record instead. On staging, a Deutsche Bahn ticket that arrived before the PDFium text-layer tier existed created an `Unknown` sender. A fix that lets the classifier leave the sender empty is deferred. **Confirm new senders** leaves that name out.
- **Document page updates and non-UUID addresses.** The document page does not refresh while its document is still processing, so reload the page. A document address that is not a UUID shows the framework's generic error screen instead of the not-found page.
- **Duplicate detection.** Schublade archives the same file as often as it arrives. A file hash catches only byte-identical files, and a second scan of the same letter is a different file, so duplicate detection needs a more robust approach.
- **Trash.** Deletion is permanent after a confirmation. A trash is planned for after phase 5. It adds a filter to every listing and a purge job.
- **Names of failed documents.** Schublade does not store file names, so a failed document reads `Untitled document` in the archive and in **Pending verification**.
- **Retrying mail.** Retrying a document that arrived by email classifies it without the email's subject and body, because Schublade does not store them.
- **Workflow start failure during upload.** When the workflow cannot start, the tray shows a refusal, and the document also appears in **Pending verification** as failed. Uploading the file again creates a second document.
- **Review controls on phones.** The review controls sit below the full document page, so each entry needs a scroll on a phone.
- **Thumbnail limits.** PDF thumbnails are grayscale, because `rasterizePage` renders for text recognition. An image original is served at full size as its own thumbnail. A PDF that cannot be rendered tries again on each request.
