# Schublade

Schublade is an open-source, self-hosted document archive that runs on your own Cloudflare account. The name is German for "drawer" and is also an acronym for *Schnell und Bequem Lagern aller Dokumente elektronisch*.

Schublade is for a person or a household that wants paper and PDF mail archived and searchable without manual tagging. If you are comfortable with a terminal and a Cloudflare account, you can run your own archive without managing servers.

## Status

Phases 0, 1, and 2 are complete and deployed to the `schublade-staging` Worker on `workers.dev` behind Cloudflare Access. You can provision an environment, upload PDF, JPEG, PNG, and WebP files, search and filter the archive, and inspect archived originals and extracted Markdown. The archive page polls while documents process. On staging, a scanned dental invoice stored in R2 and run as a workflow instance through the `cf` CLI archived in about 20 seconds with every expected field correct. After the phase 2 deployment, the scheduled backfill indexed the three existing staging documents within two minutes. A query for the dental invoice's IBAN on the staging index returned that document as the only result.

On the 12 synthetic test documents, the default `@cf/deepseek-ai/deepseek-v4.1-flash-1017` model matched 80 of 80 expected fields. An earlier run matched 79 of 80 fields because a supermarket receipt fixture expected `Frischemarkt Talbrück` instead of the printed legal name `Frischemarkt Talbrück GmbH`. After the fixture correction and the narrower euro-sign repair, `pnpm evaluate:extraction` matched all 12 documents in 55 seconds of wall time and cost 0.036 USD. `pnpm evaluate:search` passed 8 of 8 hybrid search and filter checks against those 12 documents.

API tokens and email in phase 3 and the **Pending verification** view in phase 4 are not built yet. Live WebSocket updates in phase 5, the `/mcp` server in phase 6, and mobile installation in phase 7 also remain planned. `pnpm run provision` does not yet add an Access bypass for `/api/documents/ingest` and `/mcp`. The workflow refuses a document with more than 50 pages without a text layer before it transcribes any page and sets the status to `failed`. That 50-page limit caps OCR cost at about 0.04 USD per document. A workflow step result over about 1 MiB of Markdown still fails the step, and the workflow does not truncate the classifier input. In text search, tag and amount filters see only documents in the top 50 matching chunks, and the index backfill stops at 5,000 items.

## What it does

This section describes the full design, and items marked (planned) are not built yet. Schublade takes in your mail and scans, extracts structured metadata, and indexes every page for search:

- **Three ways to add documents.** Upload files in the desktop browser or the installable mobile web app (planned). Browser uploads detect PDF, JPEG, PNG, and WebP from the file's leading bytes. Each request accepts up to 25 MB per file and 50 MB total, and each rejected file shows its reason. You can also forward an email or send a scan from an app such as QuickScan through a token-authenticated endpoint (planned). Schublade does not send email.
- **Immediate archiving with no manual tagging.** Every document enters the archive as soon as ingestion finishes. Schublade classifies each document with a title, a document date, a sender, a category, a person, tags, and a two-sentence summary. It also extracts category-specific fields such as amount, due date, IBAN, and policy number.
- **Non-blocking verification.** The **Pending verification** view (planned) surfaces only three cases. It lists a new sender, category, or tag that the model created, an illegible required field, or a non-archival email attachment. Each document stores one verification reason, and an illegible required field takes precedence over a new taxonomy record. Ignoring **Pending verification** never blocks archiving or search.
- **Hybrid multilingual search and filters.** Keyword and semantic search run together across languages, and results include the best matching passage per document. An English query finds a German invoice, and exact IBANs and invoice numbers match. The search input takes focus on `/`, Cmd+K, or Ctrl+K, and facets filter by person, sender, category, tag, date range, and amount. Search state lives in the URL, so you can share a search as a link. On phones, facets fold behind a filter button. Below the `md` CSS breakpoint, the document table becomes one stacked row per document with no horizontal scrolling at 375 px.
- **One archive for a household.** One deployment serves one household with one or more members. Cloudflare Access controls sign-in by email. Because the household is trusted, every member sees every document. Schublade assigns each document to the member it concerns, such as a child named as the patient on a parent's dental invoice, or to `household`. You can filter by person.
- **On-Cloudflare OCR and inference.** The Worker renders scanned pages at 150 dpi with PDFium WebAssembly and transcribes them page by page with `@cf/moondream/moondream3.1-9B-A2B`. Classification runs on `@cf/deepseek-ai/deepseek-v4.1-flash-1017` by default through AI Gateway. Schublade sends no document to a third-party model provider and needs no provider API key.
- **Low per-document cost.** `toMarkdown` extracts text from digital PDFs at no inference cost. Classification with DeepSeek V4.1 Flash costs about 0.0023 USD per document. Moondream OCR costs about 0.0008 USD per uncached scanned page.
- **External AI clients over MCP (planned).** Schublade has no built-in chat. External AI clients such as Claude can connect through the Model Context Protocol endpoint at `/mcp` with scoped OAuth grants.

## How it works

One Cloudflare Worker runs TanStack Start to serve the interface and coordinate ingestion. The Worker bundles PDFium WebAssembly in a 2.8 MiB compressed upload and starts in 39 to 70 ms. R2 stores original files and extracted Markdown at `documents/<id>/content.md`. D1 stores relational metadata, and AI Search provides full-text and semantic search.

`DocumentIngestionWorkflow` runs one step per unit of work. It extracts text with `toMarkdown`, detects pages without a text layer using PDFium, renders each scanned page in its own step, and transcribes each page with Moondream. Moondream returns 3-byte UTF-8 characters such as the euro sign as `U+FFFD`. Schublade restores `€` beside two-decimal amounts and tells the classifier that any remaining `U+FFFD` marks an unreadable character. The workflow then classifies the document with the Vercel AI SDK `generateText` function and `Output.object` through `workers-ai-provider` and AI Gateway. Finally, it archives the records in one D1 batch and uploads `<documentId>.md` with its metadata to AI Search.

A Cron Trigger every 15 minutes and `POST /api/search_index` backfill archived documents that the index lacks. Text queries run a hybrid AI Search query with metadata filters, group the top 50 chunks by document, and recheck every filter in D1. Filtering without a text query runs in D1 alone.

For planned email ingestion, Email Routing delivers inbound mail to the Worker, and Browser Run renders body-only HTML emails to PDF. The archive page polls today, Durable Objects are planned to push live status updates to connected clients, and Cloudflare Access controls sign-in. The Worker also rejects cross-origin write requests with HTTP 403. For the full architecture and rationale, read [VISION.md](VISION.md).

## Requirements

To deploy or develop Schublade, you need these accounts and tools:

- A Cloudflare account. Deployed use requires the Workers Paid plan, because scanned-page rendering needs more CPU time than the free plan's 10 ms limit per invocation. Local development works on the free plan.
- Cloudflare Zero Trust enabled on your Cloudflare account for deployed use, which is free for up to 50 users.
- Node.js and `pnpm`.
- The `cf` command-line interface.

## Getting started

To provision Schublade on your Cloudflare account, follow these steps:

1. Authenticate the `cf` CLI with your Cloudflare account:

	```sh
	cf auth login
	```

2. Install the package dependencies:

	```sh
	pnpm install
	```

3. Create a JSON file such as `household.json` that lists your household members:

	```json
	{
		"household_members": ["Alex Meyer", "Sam Meyer"]
	}
	```

4. Provision the Cloudflare resources and deploy the Worker:

	```sh
	pnpm run provision -- --worker-name schublade --access-email alex@example.com --household-members household.json
	```

	Repeat `--access-email` for each email address allowed to sign in.

`pnpm run provision` creates or reuses the D1 database `<worker>-database`, the R2 bucket `<worker>-documents`, the authenticated AI Gateway `<worker>`, and the AI Search instance `<worker>` with the custom metadata fields `person`, `sender`, `category`, and `document_date`. It applies the Drizzle migrations remotely, inserts the household members, and deploys the Worker locked. Next, it creates a Cloudflare Access allow policy for your emails and a self-hosted Access application for the Worker's `workers.dev` hostname, then deploys again with Access enabled.

The script saves your configuration in the git-ignored `schublade.deploy.json` file, so later runs of `pnpm run provision` need no flags. Rerunning the command converges and reports resources that are already present. You choose an environment by setting `--worker-name`. To override the default classification model, set `classificationModel` in `schublade.deploy.json`.

To ship code changes after provisioning, run `pnpm run deploy`.

## Development

Local development with `pnpm dev` requires `cf auth login` because Workers AI, Browser Run, and AI Search run remotely in development without deploying. Set `aiGatewayIdentifier` in `schublade.deploy.json` to an AI Gateway that exists on your account.

Local development binds `SEARCH_INDEX` to a separate remote AI Search instance named `schublade-development`, so local runs never write into a deployment's index. `pnpm run provision` does not create that instance. Before your first local run, create `schublade-development` once with the `person`, `sender`, `category`, and `document_date` metadata fields:

```sh
cf ai-search create schublade-development --custom-metadata '[{"field_name":"person","data_type":"text"},{"field_name":"sender","data_type":"text"},{"field_name":"category","data_type":"text"},{"field_name":"document_date","data_type":"datetime"}]'
```

To start the local development server and skip the Cloudflare Access check locally, run:

```sh
VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev
```

This exemption never reaches a production build.

Run `pnpm check` to execute `typecheck`, `lint`, `format:check`, `knip`, and `test`. The suite runs 46 tests in about 12 seconds with Vitest 5 across two projects, Node and `workerd` through `@cloudflare/vitest-plugin`. GitHub Actions runs `pnpm check` on each push to `main` in about 40 seconds.

Run `pnpm run generate:test-documents` to regenerate the 12 synthetic, anonymous test documents in `test_fixtures/documents/` and their expected values in `expected_extraction.json`. The output is byte-identical on every run.

To evaluate extraction accuracy against a local dev server, run `pnpm evaluate:extraction`. That command makes real, billed Workers AI calls. After the fixture correction and the narrower euro-sign repair, `pnpm evaluate:extraction` scored DeepSeek V4.1 Flash at 80 of 80 fields on all 12 documents. The batch took 55 seconds of wall time at a cost of 0.036 USD for the run. Before the fixture correction, an earlier run scored `gpt-oss-120b` at 74 of 80 and Gemma 4 26B at 70 of 80 with one failed document. That earlier three-model run cost 0.175 USD in total, and only DeepSeek V4.1 Flash had a rerun after the fixture correction.

To evaluate search and filtering against a local dev server and the `schublade-development` index, run `pnpm evaluate:search`. That command makes billed AI Search calls and, if test documents are not yet archived locally, billed Workers AI calls. `pnpm evaluate:search` passed 8 of 8 checks across cross-language queries, exact IBAN lookup, and person, category, date-range, and amount filters. Indexing the 12 test documents together took 73 to 145 seconds per item, with a median of 104 seconds. Through the local dev server, text queries took 0.5 to 2.4 seconds with a 1.7-second median, and D1-only filtering took about 10 ms.

## Further reading

Read these documents for the architecture, build plan, and repository standards:

- [VISION.md](VISION.md) covers the system architecture and design rationale.
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) covers the build order and verification checks.
- [AGENTS.md](AGENTS.md) covers contributor and coding-agent rules.

Paperless-ngx inspired Schublade. Fayaz Ahmed's [Coworkers](https://github.com/fayazara/coworkers) repository informed the runtime choices.
