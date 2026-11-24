# Schublade

Schublade is a document archive that runs on your own Cloudflare account. Upload a PDF, forward an email, or photograph a letter. Schublade reads it, gives it a title, a date, a sender, a category, and a person, and makes it searchable across languages. You tag nothing by hand.

Schublade is German for "drawer". One deployment serves one household, and everyone who can sign in sees every document. Your files and the models that read them stay on your Cloudflare account, so you need no other model provider and no API key.

The website is [schublade.org](https://schublade.org). The web app is the archive itself, and you deploy it yourself. Apps for iPhone and Mac work with it and are not released yet.

## Deploy

You need:

- A Cloudflare account on the Workers Paid plan, with Cloudflare Zero Trust enabled. The Zero Trust free plan covers 50 users.
- Node.js 24.22 or later, and pnpm.

```bash
pnpm install
pnpm exec cf auth login
echo '{ "household_members": ["Alex Meyer", "Sam Meyer"] }' > household.json
pnpm run provision -- --worker-name schublade --access-email alex@example.com --household-members household.json
```

`pnpm run provision` creates the database, storage, search index, and sign-in rules, then deploys the Worker. Run it again at any time, and it reuses what exists.

- Repeat `--access-email` for each person who may sign in and send mail.
- To use a domain on your account instead of `workers.dev`, add `--hostname archive.example.com`.
- To receive mail, add `--email-address documents@example.com`. Remove any parking CNAME or MX records on that zone's apex first.

To ship later code changes, run `pnpm run deploy`. After an upgrade, run `pnpm run provision` once, so that sign-in lets new routes through.

## Add documents

Schublade accepts PDF, JPEG, PNG, and WebP files. Send up to 20 at once, 25 MB each and 50 MB in total.

- **Browser.** Upload files in the archive. On a phone, add Schublade to your home screen and use the camera.
- **Email.** Forward mail from an allowed address to the address you provisioned. Schublade archives the attachments. It prints a message without attachments to a PDF.
- **Scanner or script.** Issue a token under **Settings**, then post your files. Any app that sends a multipart form works, such as an Apple Shortcut.

  ```bash
  curl -X POST -H "Authorization: Bearer <token>" -F "files=@invoice.pdf;type=application/pdf" https://<host>/api/documents/ingest
  ```

- **Folder collector.** A program watches your folders, asks the archive which files it lacks, and sends only those. [notes/client_protocol.md](notes/client_protocol.md) describes its routes.

Schublade keeps each file once, by the SHA-256 of its bytes. Send the same file again, by any route, and you get the document that already holds it. A renamed copy is the same file. Another scan of the same letter is a new one.

A file that Schublade cannot read appears under **Failed documents**, where you retry or delete it.

## Connect an AI client

Add `https://<host>/mcp` as a connector in Claude or another MCP client. A consent page lets you allow the whole archive or only the categories, senders, and tags you select. The client gets four read-only tools: `search_documents`, `list_documents`, `read_document`, and `list_filter_options`. To end its access, select **Disconnect** under **Settings**.

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

A PDF with a readable text layer skips text recognition. Classification costs about 0.0023 USD per document, and each recognized page costs about 0.0008 USD.

Workers Free is a goal. Today, reading a scanned page takes more CPU time than the 10 ms the free plan allows.

## Development

Development uses your Cloudflare login, because Workers AI, Browser Run, Images, and AI Search run remotely. Set `aiGatewayIdentifier` in `schublade.deploy.json` to an AI Gateway on your account, and create the development search index once:

```bash
pnpm exec cf ai-search create schublade-development --custom-metadata '[{"field_name":"person","data_type":"text"},{"field_name":"sender","data_type":"text"},{"field_name":"category","data_type":"text"},{"field_name":"document_date","data_type":"datetime"}]'
```

Then start the server and run the checks:

```bash
VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev   # http://localhost:3000, without the Access check
pnpm check                                        # types, lint, format, unused code, and tests
pnpm --dir public_website install --ignore-workspace   # the website's own dependencies, once
pnpm website:check                                # checks and builds the website
```

The repository holds three projects:

- `src/` is the archive, the Worker described above.
- `native_client/` holds the iPhone and Mac apps and the folder collector, in Rust and Swift.
- `public_website/` is the website, static Astro pages in English and German.

[AGENTS.md](AGENTS.md) holds the rules for contributors and coding agents.

Paperless-ngx inspired Schublade. Fayaz Ahmed's [Coworkers](https://github.com/fayazara/coworkers) repository informed its runtime choices.
