# Schublade

Schublade is an open-source, self-hosted document archive that runs on your own Cloudflare account. The name is German for "drawer" and is also an acronym for *Schnell und Bequem Lagern aller Dokumente elektronisch*.

Schublade is for a person or a household that wants paper and PDF mail archived and searchable without manual tagging. If you are comfortable with a terminal and a Cloudflare account, you can run your own archive without managing servers.

## Status

Schublade is under construction. Nothing is deployable yet. The repository currently contains the architecture document in [VISION.md](VISION.md), the build order in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md), and a generator for synthetic test documents.

## What it does

Schublade takes in your mail and scans, extracts structured metadata, and indexes every page for search:

- **Three ways to add documents.** Upload files in the desktop browser or the installable mobile web app. You can also forward an email or send a scan from an app such as QuickScan through a token-authenticated endpoint. Schublade does not send email.
- **Immediate archiving with no manual tagging.** Every document enters the archive as soon as ingestion finishes. Schublade classifies each document with a title, a document date, a sender, a category, a person, tags, and a two-sentence summary. It also extracts category-specific fields such as amount, due date, IBAN, and policy number.
- **Non-blocking verification.** The **Pending verification** view surfaces only three cases. It lists a new sender, category, or tag that the model created, an illegible required field, or a non-archival email attachment. Ignoring **Pending verification** never blocks archiving or search.
- **Hybrid multilingual search and filters.** Keyword and semantic search run together across languages. An English query finds a German invoice, and exact IBANs and invoice numbers match. You can also filter by person, sender, category, tag, date range, and amount.
- **One archive for a household.** One deployment serves one household with one or more members. Cloudflare Access controls sign-in by email. Because the household is trusted, every member sees every document. Schublade assigns each document to one member or to the whole household, and you can filter by person.
- **On-Cloudflare OCR and inference.** The Worker renders scanned pages and transcribes them page by page with a Workers AI vision model. All inference runs on Workers AI through AI Gateway. Schublade sends no document to a third-party model provider and needs no provider API key.
- **External AI clients over MCP.** Schublade has no built-in chat. External AI clients such as Claude can connect through the Model Context Protocol endpoint at `/mcp` with scoped OAuth grants.

## How it works

One Cloudflare Worker runs TanStack Start to serve the interface and coordinate ingestion. R2 stores original files, D1 stores relational metadata, and AI Search provides full-text and semantic search. Cloudflare Workflows runs the ingestion pipeline and calls Workers AI through AI Gateway for OCR and classification. Email Routing delivers inbound mail to the Worker, and Browser Run renders body-only HTML emails to PDF. Durable Objects push live status updates to connected clients, and Cloudflare Access controls sign-in. For the full architecture and rationale, read [VISION.md](VISION.md).

## Requirements

To run or develop Schublade, you need these tools and accounts:

- A Cloudflare account on the Workers Paid plan, because scanned-page rendering needs more CPU time than the free plan's 10 ms per invocation.
- Cloudflare Zero Trust enabled on your Cloudflare account, which is free for up to 50 users.
- Node.js and `pnpm`.
- The `cf` command-line interface.

## Getting started

Nothing is deployable yet. The provisioning script and the application runtime are still under construction.

When deployment is available, `pnpm run provision` will set up your Cloudflare account in one step. That planned command will create the D1 database, the R2 bucket, the AI Search instance, and the AI Gateway. It will then deploy the Worker locked, configure the Cloudflare Access application with your email allowlist, and deploy again with Access enabled.

## Development and test documents

Today, you can install the dependencies and run the test document generator:

1. Install the package dependencies:

	```sh
	pnpm install
	```

2. Generate the synthetic test documents:

	```sh
	pnpm run generate:test-documents
	```

Running `pnpm run generate:test-documents` regenerates the twelve synthetic, anonymous test documents in `test_fixtures/documents/` and their expected values in `expected_extraction.json`. The output is byte-identical on every run.

## Further reading

Read these documents for the architecture, build plan, and repository standards:

- [VISION.md](VISION.md) covers the system architecture and design rationale.
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) covers the build order and verification checks.
- [AGENTS.md](AGENTS.md) covers contributor and coding-agent rules and is currently in progress.

Paperless-ngx inspired Schublade. Fayaz Ahmed's [Coworkers](https://github.com/fayazara/coworkers) repository informed the runtime choices.
