# Schublade implementation plan

This plan turns [VISION.md](VISION.md) into a build order. Each phase ends in a check you run against the staging deployment at `staging.schublade.org`. Do not start a phase until the check of the previous phase passes.

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

The one cost that could justify a split is startup time. The runtime compiles the 4.6 MiB WebAssembly module when an isolate starts, and every isolate that serves the web interface would pay for it. Phase 1 measures cold-start latency on staging with and without PDFium. Move PDFium into its own Worker only if that measurement shows a delay you notice in the interface.

A clean synthetic page is the easy case. Phase 1 repeats the measurement on the committed test documents, which include a faded thermal receipt photo.

## Quality tooling

The [coworkers](https://github.com/fayazara/coworkers) repository runs on the same stack: TanStack Start, `cf` with `cloudflare.config.ts`, and Cloudflare Access. Schublade adopts these practices from it:

1. **Agent guidance.** `AGENTS.md` holds a map from each subsystem to its files, a list of known pitfalls, ranked rules, and the documentation lookup order. `CLAUDE.md` contains only `@AGENTS.md`. Project skills live in `.agents/skills/`, and `.claude/skills` is a symbolic link to that folder. The first skills are `new-database-table` and `add-binding`.
2. **Binding types.** The `typecheck` script runs `cf workers types && tsc --noEmit`, so binding types never go stale. The generated `.cloudflare/types` folder is ignored by git.
3. **Migrations.** `drizzle-kit generate` writes the SQL, and `cf d1 migrations apply` applies it with `--persist-to .cloudflare/state`. A `predev` script migrates the local database. `drizzle-kit push` is never used.
4. **Exact pins for beta packages.** Pin `cf` and `@cloudflare/vite-plugin` to exact versions. Use `onlyBuiltDependencies` in `pnpm-workspace.yaml` to allow install scripts only for `esbuild`, `workerd`, and `sharp`.
5. **Pure logic outside Durable Objects and Workflows.** Workflow steps and `ArchiveCoordinator` call pure modules through small port interfaces. Tests replace the ports with fakes.
6. **Errors as values.** Operations return `{ ok: false, code, error }` with a closed union of failure codes, and `executeOperation` maps each code to an HTTP status or an MCP error.
7. **Parsing at the boundary.** Every request body, email, and model output passes through Zod `safeParse`. Table inputs derive from the Drizzle schema with `drizzle-zod`.
8. **Deployment safety.** `previewUrls: false`, because preview hostnames are outside the Access application. `observability: { enabled: true }`. Server-side source maps are uploaded by `cf deploy`.
9. **Checks that name the fix.** A deployment fact learned the hard way becomes a check that throws with the fix in its message.

Schublade also closes the gaps that repository leaves open:

- **Fail closed.** The coworkers server treats every request as a demo user when the Access variables are blank. Schublade rejects every browser request when `ACCESS_TEAM_DOMAIN` or `ACCESS_AUD` is absent.
- **One gate, run before every push.** The coworkers repository has a lint configuration but nothing that runs it. In Schublade, `pnpm check` runs `typecheck`, `lint`, `format:check`, `knip`, and `test` in sequence. A `pre-push` git hook installed by `simple-git-hooks` runs `pnpm check`, so a failing change never reaches `main`.
- **Pinned toolchain.** `packageManager` in `package.json` and a `.node-version` file pin pnpm and Node.
- **Binding tests.** Vitest runs two projects. Pure modules run in Node. Tests that touch D1, R2, Workflows, or Durable Objects run in `workerd` through `@cloudflare/vitest-pool-workers`.

### Commits go straight to `main`

Schublade uses no pull requests. Each change is one commit pushed to `main` after `pnpm check` passes locally. A GitHub Actions workflow runs `pnpm check` once on each push to `main` as a safety net. It caches the pnpm store, cancels a run that a newer push supersedes, and skips pushes that change only Markdown files. Dependency upgrades are deliberate commits made with `pnpm update`, because a dependency bot works only through pull requests.

### Test budget

The test suite stays small and fast, so it costs almost nothing on GitHub Actions or Cloudflare.

- **Targets.** `pnpm check` finishes in under one minute on a laptop, and the GitHub Actions run finishes in under three minutes. A test that pushes the suite past either target needs a reason in its commit message.
- **No Cloudflare usage in tests.** `@cloudflare/vitest-pool-workers` simulates D1, R2, Workflows, and Durable Objects locally in Miniflare, so tests make no billed requests. The Workers AI and AI Search bindings are replaced by recorded responses.
- **Few `workerd` tests.** The `workerd` project starts more slowly than the Node project, so it covers only the parts that need real bindings: the D1 queries with scope predicates, the workflow step sequence, and the `ArchiveCoordinator` broadcast. Everything else is a pure module tested in Node.
- **One test per behavior.** Tests assert literal expected values from `expected_extraction.json` or written into the test. Snapshot tests and browser end-to-end tests are not part of the suite. The interface is verified by hand on staging at the end of each phase.
- **Model evaluation stays manual.** `pnpm evaluate:extraction` calls the real Workers AI models and runs only when you start it, after a change to a prompt, a model, or the OCR path.

Lint and formatting use ESLint with `@tanstack/eslint-config` and Prettier with `prettier-plugin-tailwindcss`, matching the TanStack Start ecosystem. `knip` reports unused files, exports, and dependencies.

## Test documents

`test_fixtures/documents/` holds synthetic, anonymous documents generated by `scripts/generate_test_documents.ts`. They cover every category, digital and scanned PDFs, a phone photo of a receipt, multi-page documents, an English invoice, and an email boilerplate attachment. `expected_extraction.json` records the literal values printed on each document. The fictional household has two adults and one child, and every person, company, address, and IBAN is invented. Regenerate the set with `pnpm generate:test-documents`. The generator is deterministic, so a regeneration that changes bytes shows up in review.

Tests assert against `expected_extraction.json`:

- **Deterministic tests** run in `pnpm check`. They cover text layer detection, page rendering, page counts, and the D1 and AI Search writes, with the Workers AI binding replaced by a recorded response.
- **The model evaluation** runs on demand with `pnpm evaluate:extraction` against the real Workers AI binding. It reports, per document and per field, whether the extracted value matches. It is not part of `pnpm check`, because model output is not deterministic and every run costs money.

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
| Tests | Vitest, `@cloudflare/vitest-pool-workers` |
| Quality | ESLint, `@tanstack/eslint-config`, Prettier, `prettier-plugin-tailwindcss`, `knip`, `simple-git-hooks` |

## Build order

### Phase 0. Scaffold, quality gates, and authentication

1. Generate the project with `pnpm create cloudflare@latest --framework=tanstack-start` and merge it into the repository, keeping the existing `package.json` scripts.
2. Run `cf migrate` to convert it to `cloudflare.config.ts`, with a `staging` mode.
3. Add the quality tooling above: `AGENTS.md`, `CLAUDE.md`, the two Vitest projects, ESLint, Prettier, `knip`, `pnpm check`, the `pre-push` hook, and the GitHub Actions workflow on pushes to `main`.
4. Define the Drizzle schema with all nine tables and apply the first migration to D1.
5. Add the Access JWT verification middleware in `src/server.ts`, failing closed.
6. Seed the household members with `scripts/provision_environment.ts`.
7. Deploy to `staging.schublade.org` behind Access.

**Check.** The staging page lists the seeded household members. A request without an Access JWT returns 403. A deployment with blank Access variables returns 403 for every browser request. `pnpm check` passes in under one minute, and the GitHub Actions run on the first push to `main` passes.

### Phase 1. Ingestion core with OCR

1. The upload control writes the file to R2, inserts a `documents` row with the status `processing`, and starts `DocumentIngestionWorkflow`.
2. The workflow runs `toMarkdown()`. For pages without a text layer, and for image uploads, it renders each page with PDFium and transcribes it with Moondream, one workflow step per page.
3. The workflow reads the taxonomy and household members from D1, calls `generateObject()` on a Workers AI text model chosen from the live catalog, and writes metadata, extracted fields, and person.
4. The document table lists rows. The inspection pane shows the original file and the Markdown text. A TanStack Query `refetchInterval` updates rows while any document is processing.
5. Add `pnpm evaluate:extraction` and run it over `test_fixtures/documents/`. If Moondream misreads the thermal receipt or dense pages, test 200 dots per inch and splitting a page into upper and lower halves before changing the model.

6. Measure cold-start latency of the web interface on staging with and without PDFium in the bundle, as described in [One Worker, not a dedicated OCR Worker](#one-worker-not-a-dedicated-ocr-worker).

**Check.** Every test document reaches `archived`. The evaluation report shows the category, sender, person, document date, and amount correct for every document, and the result and the cold-start measurement are recorded in this file.

### Phase 2. Search

1. The workflow uploads the enriched Markdown to AI Search as `<documentId>.md` with the metadata fields from VISION.md.
2. The search operation queries AI Search in hybrid mode with the person, sender, category, and date filters, then joins the candidates with D1 and applies tag and scope predicates.
3. The center pane gains the search input and the facet controls, including the person filter.

**Check.** An English query finds a German invoice. An exact IBAN string finds its document. Filtering a search to one member returns every matching document of that member, not a subset of the unfiltered top results.

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

Add `/mcp` with `McpAgent` and `@cloudflare/workers-oauth-provider`, with the consent screen behind Access.

**Check.** Claude connects with a grant restricted to `allowedCategories: ["Invoice"]` and cannot read any other category through search or listing.

### Phase 7. HTML email and mobile

1. Render body-only HTML emails to PDF on Browser Run.
2. Add the Web App Manifest, the mobile bottom action bar, and the `Drawer` layout.

**Check.** A forwarded App Store receipt archives as a PDF. The installed home screen application uploads from the camera.
