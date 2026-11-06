# Schublade

Schublade is an open-source, self-hosted document archive that runs on your own Cloudflare account. The name is German for "drawer" and is also an acronym for *Schnell und Bequem Lagern aller Dokumente elektronisch*.

Schublade is for a person or a household that wants paper and PDF mail archived and searchable without manual tagging. If you are comfortable with a terminal and a Cloudflare account, you can run your own archive without managing servers.

## Status

Phases 0, 1, 2, 3, and 4 are complete. Staging runs at `https://staging.schublade.org` behind Cloudflare Access, and its `workers.dev` hostname is off and returns HTTP 404. You can provision an environment, upload PDF, JPEG, PNG, and WebP files in the browser or through `POST /api/documents/ingest`, and forward email with attachments. In the web interface, you can issue and revoke API tokens on **Settings**, search and filter the archive, inspect and edit documents, and resolve items on **Pending verification**.

On staging, an invoice uploaded with a bearer token archived with every expected field, and the token stopped working after revocation. A real email from an allowlisted Gmail address with a PDF attachment passed DMARC and archived. A tagged Apache FOP train ticket that `toMarkdown` left blank extracted through the PDFium fallback and classified with no Moondream call. Migrations `0001` and `0002` applied on staging, where they confirmed standard categories, cleared stored `new_taxonomy_record` reasons, and set `indexed_at` on every archived document. On the 12 synthetic test documents, `pnpm evaluate:extraction` with `@cf/deepseek-ai/deepseek-v4.1-flash-1017` scored 91 of 92 expected fields in its latest runs, including 12 of 12 on the non-archival flag. `pnpm evaluate:search` passed 8 of 8 hybrid search and filter checks against those 12 documents. In local checks, merging a sender removed the old sender from the search index, and deleting a document removed its files, rows, and search item.

Live WebSocket updates in phase 5, the `/mcp` server in phase 6, and mobile installation and HTML-to-PDF email rendering in phase 7 are not built yet. A rate limit on `/api/documents/ingest` and a signed-in check of **Pending verification** on staging also remain open. The workflow fails any PDF that needs Moondream on more than 50 pages. That 50-page limit caps OCR cost at about 0.04 USD per document. In PDFium text extraction, a glyph without a Unicode mapping can produce a wrong letter that the `U+FFFD` check does not catch. A workflow step result over about 1 MiB of Markdown still fails the step, and the workflow does not truncate classifier input. In text search, tag and amount filters see only documents in the top 50 matching chunks, and the index backfill stops at 5,000 items. A category merge reads moved documents just before its D1 batch, so an overlapping edit can be reassessed from older fields. Two concurrent deletions of the same document can report an AI Search error on one call, and a rerun converges.

## What it does

This section describes the full design, and items marked (planned) are not built yet. Schublade takes in your mail and scans, extracts structured metadata, and indexes every page for search:

- **Three ways to add documents.** Upload files in the desktop browser or the installable mobile web app (planned). You can also forward an email or send a scan from an app such as QuickScan through a token-authenticated endpoint. Uploads and inbound emails detect PDF, JPEG, PNG, and WebP from the file's leading bytes and accept up to 20 files, 25 MB per file, and 50 MB total. Schublade does not send email.
- **Immediate archiving with no manual tagging.** Every document enters the archive as soon as ingestion finishes. Schublade classifies each document with a title, a document date, a sender, a category, a person, tags, and a two-sentence summary. It also extracts category-specific fields such as amount, due date, IBAN, and policy number.
- **Non-blocking verification and editing.** The **Pending verification** view shows a count badge in the navigation and lists three kinds of items: an unconfirmed sender, category, or tag that the classifier created with every document that refers to it, a document with illegible required fields and its missing fields, and a non-archival attachment such as general terms, a privacy notice, or advertising. Confirming one taxonomy record resolves all of its documents at once, and `non_archival_attachment` takes precedence over `illegible_required_field` on a document. From **Pending verification**, you can confirm, rename, or merge a record, delete an unused unconfirmed record, supply a missing field, keep a non-archival attachment, or delete a document. Renaming a record onto an existing name proposes a merge, and every merge or deletion asks for confirmation in a dialog that states what will happen, such as how many documents move. In the archive's inspection pane, you can edit a document's title, document date, sender, category, person, tags, and extracted fields, or delete the document. Ignoring **Pending verification** never blocks archiving or search.
- **Hybrid multilingual search and filters.** Keyword and semantic search run together across languages, and results include the best matching passage per document. An English query finds a German invoice, and exact IBANs and invoice numbers match. The search input takes focus on `/`, Cmd+K, or Ctrl+K, and facets filter by person, sender, category, tag, date range, and amount. Search state lives in the URL, so you can share a search as a link. On phones, facets fold behind a filter button. Below the `md` CSS breakpoint, the document table becomes one stacked row per document with no horizontal scrolling at 375 px.
- **One archive for a household.** One deployment serves one household with one or more members. Cloudflare Access controls sign-in by email. Because the household is trusted, every member sees every document. Schublade assigns each document to the member it concerns, such as a child named as the patient on a parent's dental invoice, or to `household`. You can filter by person.
- **On-Cloudflare OCR and inference.** The Worker extracts digital PDF text with `toMarkdown` and PDFium WebAssembly, renders scanned pages at 150 dpi with PDFium, and transcribes them with `@cf/moondream/moondream3.1-9B-A2B`. Classification runs on `@cf/deepseek-ai/deepseek-v4.1-flash-1017` by default through AI Gateway. Schublade sends no document to a third-party model provider and needs no provider API key.
- **Low per-document cost.** `toMarkdown` and PDFium extract text from digital PDFs at no inference cost. Classification with DeepSeek V4.1 Flash costs about 0.0023 USD per document. Moondream OCR costs about 0.0008 USD per uncached scanned page.
- **External AI clients over MCP (planned).** Schublade has no built-in chat. External AI clients such as Claude can connect through the Model Context Protocol endpoint at `/mcp` with scoped OAuth grants.

## How it works

One Cloudflare Worker runs TanStack Start to serve the interface and coordinate ingestion. The Worker bundles PDFium WebAssembly in a 2.8 MiB compressed upload and starts in 39 to 70 ms. R2 stores original files and extracted Markdown at `documents/<id>/content.md`. D1 stores relational metadata, and AI Search provides full-text and semantic search.

`DocumentIngestionWorkflow` runs one step per unit of work. For each PDF page, the workflow keeps `toMarkdown` text with at least 40 letters or digits, or PDFium text with at least 40 and under one `U+FFFD` replacement character per ten. PDFium reads tagged PDFs whose structure tree `toMarkdown` cannot follow, while remaining PDF pages and uploaded images render at 150 dpi in separate steps for Moondream transcription. Moondream returns 3-byte UTF-8 characters such as the euro sign as `U+FFFD`. Schublade restores `€` beside two-decimal amounts and tells the classifier that any remaining `U+FFFD` marks an unreadable character. The workflow then classifies the document with the Vercel AI SDK `generateText` function and `Output.object` through `workers-ai-provider` and AI Gateway. Finally, it archives the records in one D1 batch and uploads `<documentId>.md` with its metadata to AI Search.

Each document records its last indexed revision in `indexed_at`. Editing a single document re-uploads its search item in the same request, and taxonomy renames and merges mark moved documents stale. A Cron Trigger every 15 minutes and `POST /api/search_index` upload missing, failed, and stale documents. Text queries run a hybrid AI Search query with metadata filters, group the top 50 chunks by document, and recheck every filter in D1. Filtering without a text query runs in D1 alone.

Every request resolves to one of three callers: `member_session` from a verified Cloudflare Access assertion, `api_token` with its authorization scope, or `inbound_mail` from a verified sender address. One table assigns each operation its minimum level in the order `read` < `ingest` < `modify` < `administer`: editing and supplying fields require `modify`, while merging and deleting require `administer`. The Worker refuses cross-site write requests with HTTP 403. Cloudflare Access gates every HTTP route except the exact path `/api/documents/ingest`, where an Access bypass application exposes `POST /api/documents/ingest` for bearer tokens. Email Routing delivers inbound mail to the Worker, while HTML-to-PDF rendering with Browser Run and live status updates over Durable Objects remain planned. For the full architecture and rationale, read [VISION.md](VISION.md).

## Requirements

To deploy or develop Schublade, you need these accounts and tools:

- A Cloudflare account. Deployed use requires the Workers Paid plan, because scanned-page rendering needs more CPU time than the free plan's 10 ms limit per invocation. Local development works on the free plan.
- Cloudflare Zero Trust enabled on your Cloudflare account for deployed use. The free plan covers up to 50 users.
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
	pnpm run provision -- --worker-name schublade --access-email alex@example.com --household-members household.json --hostname archive.example.com --email-address documents@example.com
	```

	Repeat `--access-email` for each email address allowed to sign in and send mail. Omit `--hostname` to keep the `workers.dev` hostname, and omit `--email-address` to skip Email Routing.

`pnpm run provision` creates or reuses the D1 database `<worker>-database`, the R2 bucket `<worker>-documents`, the authenticated AI Gateway `<worker>`, and the AI Search instance `<worker>`. It configures the index with the custom metadata fields `person`, `sender`, `category`, and `document_date`. It applies the Drizzle migrations remotely, inserts the household members, and deploys the Worker locked. Next, it creates an Access allow policy for your emails, an Access application for the Worker hostname, and a bypass application for `/api/documents/ingest`. It then redeploys the Worker with Access enabled.

When `--hostname` attaches a custom domain on a zone in your account, the Worker disables `workers.dev`. The script covers the new hostname in Access before the deployment moves the route and removes the old hostname afterward. When `--email-address` enables Email Routing on that address's zone, remove any conflicting parking CNAME or MX records on the zone apex first.

The script saves your configuration in the git-ignored `schublade.deploy.json` file, so later runs of `pnpm run provision` need no flags. Reruns converge and report resources that already exist. To override the default classification model, set `classificationModel` in `schublade.deploy.json`. To ship code changes after provisioning, run `pnpm run deploy`.

## Send documents by email and from scanners

When you provision with `--email-address`, Email Routing delivers mail for that address to the Worker. The Worker checks the recipient and envelope sender before it parses the message. It admits a message only when the recipient matches the ingestion address, the envelope sender and the single `From` header match the same allowlisted Access email address, and `mx.cloudflare.net` reports `dmarc=pass` in the header block that Email Routing prepends before the next `Received` header. Because domains such as `gmail.com` publish a DMARC policy of `none`, Email Routing would deliver spoofed messages without that `dmarc=pass` check.

The Worker ingests PDF, JPEG, PNG, and WebP attachments with the email subject, sender, and plain-text body as classification context. It skips inline images under 15 KB, stores messages without a usable attachment as `awaiting_rendering` for phase 7 HTML-to-PDF rendering, and ignores redeliveries with the same `Message-ID`.

Signed-in members have the `administer` permission level and can issue and revoke API tokens on the **Settings** page. Each token has the `ingest` permission level, starts with `schublade_` followed by 43 random base64url characters, and appears once at creation. D1 stores only the token's SHA-256 digest, updates its last-used time at most once per hour, and deletes the row on revocation.

`POST /api/documents/ingest` accepts the same multipart `files` field as the browser upload with an `Authorization: Bearer <token>` header and no Access sign-in. A missing or unknown token returns HTTP 401, `GET` returns HTTP 405, and any subpath returns HTTP 403. To upload a file from a terminal or scanner script, run `curl`:

```sh
curl -X POST -H "Authorization: Bearer <token>" -F "files=@invoice.pdf;type=application/pdf" https://<host>/api/documents/ingest
```

The endpoint responds with a JSON outcome per file, such as `{"kind":"accepted",...}`.

To send scans from QuickScan or another iOS app, build an Apple Shortcut that posts to the ingest endpoint. These steps were not run:

1. Open **Settings**, issue a token with the **Ingest documents** permission, and copy the token while it is shown.
2. In the Apple Shortcuts app, create a Shortcut that receives PDFs from the **Share Sheet**.
3. Add a **Repeat with Each** action over **Shortcut Input**.
4. Inside the loop, add **Get Contents of URL** for `https://<host>/api/documents/ingest` with method **POST** and the header `Authorization: Bearer <token>`.
5. Set **Request Body** to **Form** and add a **File** field named `files` holding **Repeat Item**.
6. Add an action to show the result, then share a scan to the Shortcut.

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

Run `pnpm check` to execute `typecheck`, `lint`, `format:check`, `knip`, and `test`. The suite runs 89 tests in about 15 seconds with Vitest 5 across two projects, Node and `workerd` through `@cloudflare/vitest-plugin`. GitHub Actions runs `pnpm check` on each push to `main` in about 40 seconds.

Run `pnpm run generate:test-documents` to regenerate the 12 synthetic, anonymous test documents in `test_fixtures/documents/` and their expected values in `expected_extraction.json`. The output is byte-identical on every run.

To evaluate extraction accuracy against a local dev server, run `pnpm evaluate:extraction`. That command makes billed Workers AI calls and scored DeepSeek V4.1 Flash at 91 of 92 fields in its latest runs across all 12 documents, including 12 of 12 on the non-archival flag. To evaluate search and filtering against a local dev server and the `schublade-development` index, run `pnpm evaluate:search`. That command makes billed AI Search calls and passed 8 of 8 checks across cross-language queries, exact IBAN lookup, and person, category, date-range, and amount filters.

## Further reading

Read these documents for the architecture, build plan, and repository standards:

- [VISION.md](VISION.md) covers the system architecture and design rationale.
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) covers the build order and verification checks.
- [AGENTS.md](AGENTS.md) covers contributor and coding-agent rules.

Paperless-ngx inspired Schublade. Fayaz Ahmed's [Coworkers](https://github.com/fayazara/coworkers) repository informed the runtime choices.
