---
title: "Schublade vs Paperless-ngx: two self-hosted document archives"
description: "Schublade or Paperless-ngx? Compare hosting, upkeep, text recognition, classification, email intake, apps, household sharing, and cost, checked November 2026."
competitor: "Paperless-ngx"
competitorUrl: "https://docs.paperless-ngx.com/"
verifiedOn: 2026-11-24
summary: "Choose Schublade if you want a household archive on your own Cloudflare account, with no server to look after and a language model that files every document. Choose Paperless-ngx if you want everything on your own hardware, need permissions per person, or archive Office files."
aspects:
  - aspect: "Where it runs and where files live"
    schublade: "One Cloudflare Worker on your own Cloudflare account. Files sit in R2 and records in D1 on that account."
    competitor: "Your own server, usually with Docker Compose. Paperless-ngx stores them as plain files on that server's disk."
  - aspect: "Who maintains the server"
    schublade: "Cloudflare runs the platform. You deploy new versions with one command."
    competitor: "You do. A web server, a task processor, a Redis-compatible broker, and a database such as PostgreSQL."
  - aspect: "Text recognition"
    schublade: "Uses a PDF's own text layer when it is readable. Scans and photos go to the Moondream 3.1 vision model on Workers AI."
    competitor: "Tesseract, which recognizes more than 100 languages. Remote recognition through Azure AI Document Intelligence is opt-in."
  - aspect: "Automatic classification"
    schublade: "A language model sets title, date, sender, category, and household member, and extracts amounts and IBANs. Nothing to train."
    competitor: "A machine-learning model trained on your own documents assigns tags, correspondents, and document types. Suggestions from a language model through an OpenAI-compatible API or Ollama are opt-in."
  - aspect: "Search"
    schublade: "Keyword and semantic search across languages, through Cloudflare AI Search."
    competitor: "Full-text search with autocomplete, highlighted matches, and a search for similar documents."
  - aspect: "Email intake"
    schublade: "Forward mail from an allowed address to your archive's address. Schublade prints a message without an attachment to a PDF."
    competitor: "Fetches mail from accounts you configure, with rules per account that decide what to consume and what to do with the message afterwards."
  - aspect: "Phone app"
    schublade: "iPhone app with a document scanner and the share sheet, coming soon. Today the web app installs on the home screen and uses the camera."
    competitor: "No official app. The project wiki lists community apps for iOS and Android that the team does not endorse."
  - aspect: "Mac app"
    schublade: "Mac app with a reader, an offline copy, and a collector for chosen folders, coming soon."
    competitor: "No official app. The wiki lists community clients for macOS."
  - aspect: "Sharing within a household"
    schublade: "One household per deployment. Everyone who can sign in sees every document."
    competitor: "Users, groups, and permissions per document, plus public share links that can expire."
  - aspect: "File types"
    schublade: "PDF, JPEG, PNG, and WebP."
    competitor: "PDF, images, plain text, and Office documents. Office files and email need the optional Apache Tika."
  - aspect: "AI assistant access (MCP)"
    schublade: "Built-in MCP connector with four read-only tools. The consent page can limit it to chosen categories, senders, and tags."
    competitor: "No built-in MCP server. The wiki lists community MCP servers. A built-in document chat works with a language model you configure."
  - aspect: "Cost"
    schublade: "Cloudflare Workers Paid plan, at least 5 USD a month (Cloudflare's pricing page, read 2026-11-24), plus about 0.0023 USD per document and 0.0008 USD per recognized page."
    competitor: "Free and open source under GPL-3.0. You pay for the hardware or hosting that runs it."
sources:
  - title: "Paperless-ngx documentation: Home (docs/index.md)"
    url: "https://github.com/paperless-ngx/paperless-ngx/blob/main/docs/index.md"
  - title: "Paperless-ngx documentation: Setup (docs/setup.md)"
    url: "https://github.com/paperless-ngx/paperless-ngx/blob/main/docs/setup.md"
  - title: "Paperless-ngx documentation: Usage (docs/usage.md)"
    url: "https://github.com/paperless-ngx/paperless-ngx/blob/main/docs/usage.md"
  - title: "Paperless-ngx documentation: Administration, document exporter (docs/administration.md)"
    url: "https://github.com/paperless-ngx/paperless-ngx/blob/main/docs/administration.md"
  - title: "Paperless-ngx wiki: Related projects"
    url: "https://github.com/paperless-ngx/paperless-ngx/wiki/Related-Projects"
  - title: "Paperless-ngx repository on GitHub"
    url: "https://github.com/paperless-ngx/paperless-ngx"
  - title: "Cloudflare Workers pricing"
    url: "https://developers.cloudflare.com/workers/platform/pricing/"
---

## Two archives with the same goal

Paperless-ngx and Schublade both turn a pile of letters, bills, and receipts into a searchable archive that you host yourself. Paperless-ngx inspired Schublade. The difference lies in where the work happens and who looks after it.

Paperless-ngx is a mature, community-supported project with more than 48,000 stars on GitHub. You run it on a machine you control, most often with Docker Compose. Its documentation recommends PostgreSQL and requires a Redis-compatible broker next to the web server and the task processor. Your documents never leave that machine unless you turn on a remote service.

Schublade runs as one Cloudflare Worker on your own Cloudflare account. There is no machine to patch. A language model on Workers AI reads each document and gives it a title, a date, a sender, a category, and the household member it belongs to. Files and inference stay on your account, and you need no API key from another model provider.

## Who each one suits

Schublade suits a household that wants paperwork filed without maintaining a server or training a classifier. You forward an email, upload a photo, or post a file with a token, and the document appears with its fields filled in. Search matches meaning as well as keywords and works across languages. Read more on the [web app page](/web/).

Paperless-ngx suits people who already run a home server and want full control. It runs entirely on your own hardware. Its permission system gives each person their own documents. Its workflows decide what happens to each file. With the optional Apache Tika, it consumes Office documents such as Word and Excel files, which Schublade does not accept.

## Where Paperless-ngx is clearly ahead

- **Permissions.** Paperless-ngx has users, groups, and permissions on each document. Schublade serves one household per deployment, and everyone who signs in sees every document.
- **Maturity.** Paperless-ngx descends from Paperless and Paperless-ng and has a large community. Schublade is a young project.
- **No cloud account.** Paperless-ngx needs no cloud service. Schublade needs a Cloudflare account on the Workers Paid plan, and Cloudflare bills recognition and classification per use.
- **File types.** Schublade accepts PDF, JPEG, PNG, and WebP only.
- **Apps today.** Both projects lack an official app in a store today. Paperless-ngx has a list of community apps. Schublade's own [iPhone app](/iphone/) and [Mac app](/mac/) work, but they are not released yet.

## Where Schublade differs

Schublade keeps one document per file content. It names every file by the SHA-256 of its bytes. Sending the same bytes again returns the existing document. Paperless-ngx keeps duplicates by default and lists them on a Duplicates tab, and a setting makes it reject them instead.

Schublade's email intake needs no mailbox. You forward a message to an address on your Cloudflare domain. Schublade checks that the sender is allowed and passed DMARC, and it prints a message without an attachment to a PDF. Paperless-ngx connects to your existing mail accounts and applies rules you define.

Schublade has a built-in MCP connector. Claude or another MCP client gets four read-only tools to search, list, and read documents. The consent page can limit a connection to the categories, senders, and tags you choose. Paperless-ngx has a built-in document chat with a model you configure, and community projects provide MCP servers.

## Moving from Paperless-ngx to Schublade

1. Export your originals with the Paperless-ngx document exporter. The `--no-archive` option exports only the original files, without the PDF/A copies.
2. Deploy Schublade with `pnpm run provision` on your Cloudflare account.
3. Send the exported files to Schublade. Upload them in the browser, 20 files at a time, or issue a token under **Settings** and post them from a script to `/api/documents/ingest`. When the Mac app is released, its collector can watch the export folder and send only the files the archive lacks.

Schublade classifies every document again on arrival. Tags, correspondents, and custom fields from Paperless-ngx do not carry over. Files other than PDF, JPEG, PNG, and WebP stay behind. Because Schublade recognizes files by their bytes, you can run the upload again after an interruption, and files that already arrived come back as already archived.
