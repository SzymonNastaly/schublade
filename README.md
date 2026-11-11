# Schublade

A self-hosted document archive that runs on your own Cloudflare account. Upload a PDF, forward an email, or photograph a letter, and Schublade files it and makes it searchable with no manual tagging.

Schublade, German for "drawer", reads each document and gives it a title, a date, a sender, a category, and a person. It extracts fields such as amounts and IBANs, and it indexes the text for search across languages. One deployment serves one household, and everyone who can sign in sees every document. Files and inference stay on your Cloudflare account, so you need no third-party model provider or API key.

## Deploy

You need:

- A Cloudflare account on the Workers Paid plan, with Cloudflare Zero Trust enabled. The Zero Trust free plan covers 50 users.
- Node.js 24.22 or later, and pnpm.

Workers Free is a goal. Today, rendering a scanned page takes more CPU time than the 10 ms the free plan allows.

```bash
pnpm install
pnpm exec cf auth login
echo '{ "household_members": ["Alex Meyer", "Sam Meyer"] }' > household.json
pnpm run provision -- --worker-name schublade --access-email alex@example.com --household-members household.json
```

- Repeat `--access-email` for each person who may sign in and send mail.
- Add `--hostname archive.example.com` to use a custom domain on your account instead of `workers.dev`.
- Add `--email-address documents@example.com` to receive mail. Remove any parking CNAME or MX records on that zone's apex first.

`pnpm run provision` creates the database, storage, search index, and sign-in rules, then deploys the Worker. Run it again at any time, and it reuses what exists. To ship later code changes, run `pnpm run deploy`.

## Add documents

Schublade accepts PDF, JPEG, PNG, and WebP files, up to 20 files at once, 25 MB per file, and 50 MB in total.

- **Browser.** Upload files in the archive. On a phone, install Schublade on your home screen and use the camera.
- **Email.** Forward mail from an allowed address to the address you provisioned. Schublade archives the attachments, and it prints a message without one to a PDF.
- **Scanner or script.** Issue a token under **Settings**, then post your files. Any app that can send a multipart form works, such as an Apple Shortcut.

```bash
curl -X POST -H "Authorization: Bearer <token>" -F "files=@invoice.pdf;type=application/pdf" https://<host>/api/documents/ingest
```

Every document enters the archive as soon as it is processed. A file that Schublade cannot process, such as one it cannot open or a page it cannot read, appears under **Failed documents**, where you retry or delete it.

## Connect an AI client

Add `https://<host>/mcp` as a connector in Claude or another MCP client. A consent page lets you allow the whole archive or only the categories, senders, and tags you select. To end access, select **Disconnect** under **Settings**.

The client gets four read-only tools: `search_documents`, `list_documents`, `read_document`, and `list_filter_options`.

## How it works

One Cloudflare Worker serves the interface and runs ingestion.

| Job                                 | Runs on                                               |
| ----------------------------------- | ----------------------------------------------------- |
| Interface and server functions      | Workers with TanStack Start                           |
| Sign-in                             | Cloudflare Access                                     |
| Records                             | D1                                                    |
| Original files and extracted text   | R2                                                    |
| Ingestion steps                     | Workflows                                             |
| Keyword and semantic search         | AI Search                                             |
| Reading scanned pages and photos    | PDFium in WebAssembly, Images, and Moondream 3.1      |
| Classification                      | DeepSeek V4.1 Flash on Workers AI, through AI Gateway |
| Inbound mail and printing it to PDF | Email Routing and Browser Run                         |
| Live updates in open browsers       | Durable Objects                                       |

A PDF with a readable text layer skips text recognition. Classification costs about 0.0023 USD per document, and each recognized page about 0.0008 USD.

## Development

Development uses your Cloudflare login, because Workers AI, Browser Run, Images, and AI Search run remotely without deploying. Set `aiGatewayIdentifier` in `schublade.deploy.json` to an AI Gateway on your account, and create the development search index once:

```bash
pnpm exec cf ai-search create schublade-development --custom-metadata '[{"field_name":"person","data_type":"text"},{"field_name":"sender","data_type":"text"},{"field_name":"category","data_type":"text"},{"field_name":"document_date","data_type":"datetime"}]'
```

Then start the server and run the checks:

```bash
VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev   # http://localhost:3000, without the Access check
pnpm check                                        # types, lint, format, unused code, and tests
pnpm evaluate:extraction                          # billed: scores classification against a running server
pnpm evaluate:search                              # billed: checks fixed searches against a running server
```

## Documentation

- [AGENTS.md](AGENTS.md) holds the rules for contributors and coding agents.

Paperless-ngx inspired Schublade. Fayaz Ahmed's [Coworkers](https://github.com/fayazara/coworkers) repository informed its runtime choices.
