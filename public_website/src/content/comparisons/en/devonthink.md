---
title: "Schublade vs DEVONthink: household archive or Mac database"
description: "Schublade or DEVONthink for your paperwork? Compare where each runs, text recognition, filing, email, iPhone and Mac apps, household sharing, and price."
competitor: "DEVONthink"
competitorUrl: "https://www.devontechnologies.com/apps/devonthink"
verifiedOn: 2026-11-24
summary: "Choose Schublade if your household wants one shared archive that files paperwork by itself and that everyone reaches from a browser. Choose DEVONthink if you work on a Mac, want your documents in a local database that works offline, and value annotations, scripting, and a one-time purchase."
aspects:
  - aspect: "Where it runs"
    schublade: "One Cloudflare Worker on your own Cloudflare account, used in any browser."
    competitor: "A Mac app for macOS Ventura or later. The Server edition adds a web interface for other devices."
  - aspect: "Who maintains it"
    schublade: "Cloudflare runs the platform. You deploy new versions with one command."
    competitor: "You install and update the app on each Mac. Sync between devices goes through a location you choose."
  - aspect: "Text recognition"
    schublade: "Uses a PDF's own text layer when it is readable. Scans and photos go to the Moondream 3.1 vision model on Workers AI."
    competitor: "Scanner integration and OCR are part of the Pro and Server editions."
  - aspect: "Automatic classification"
    schublade: "A language model sets title, date, sender, category, and household member, and extracts amounts and IBANs."
    competitor: "See Also and Classify suggest related documents and groups in every edition. Pro adds tagging and summaries with a generative model."
  - aspect: "Search"
    schublade: "Keyword and semantic search across languages, through Cloudflare AI Search."
    competitor: "Searches your databases on the Mac. Pro adds assisted search with a generative model."
  - aspect: "Email intake"
    schublade: "Forward mail from an allowed address to your archive's address. Schublade prints a message without an attachment to a PDF."
    competitor: "Archives messages from Apple Mail and Microsoft Outlook on the Mac, or imports mailbox files. Requires Pro or Server."
  - aspect: "iPhone and iPad"
    schublade: "iPhone app with a document scanner, the share sheet, and an offline copy, coming soon. The web app works on a phone today."
    competitor: "DEVONthink To Go for iPhone and iPad, with a camera scanner and OCR. Included with Pro and Server licenses."
  - aspect: "Mac app"
    schublade: "Mac app with a reader, an offline copy, and a collector for chosen folders, coming soon."
    competitor: "Native Mac app, available now in version 4.4.2."
  - aspect: "Sharing within a household"
    schublade: "One household per deployment. Everyone who can sign in sees every document."
    competitor: "A license covers two Macs. The Server edition gives others browser access with granular access management."
  - aspect: "Data location"
    schublade: "Your Cloudflare account, with files in R2 and records in D1. Recognition and classification run on Workers AI in the same account."
    competitor: "Databases stay on your Mac. Sync data in iCloud, Dropbox, or WebDAV can be encrypted."
  - aspect: "AI assistant access (MCP)"
    schublade: "Built-in MCP connector with four read-only tools. The consent page can limit it to chosen categories, senders, and tags."
    competitor: "Since version 4.3, connects to AI apps that support MCP, such as Claude or Codex. Pro works with online models and local ones through Ollama or LM Studio."
  - aspect: "Cost"
    schublade: "Cloudflare Workers Paid plan, at least 5 USD a month (Cloudflare's pricing page, read 2026-11-24), plus about 0.0023 USD per document and 0.0008 USD per recognized page."
    competitor: "One-time purchase with one year of updates: Standard 99 USD, Pro 199 USD, Server 499 USD (DEVONthink pricing page, read 2026-11-24). Update extensions cost extra."
sources:
  - title: "DEVONthink product page"
    url: "https://www.devontechnologies.com/apps/devonthink"
  - title: "DEVONthink pricing"
    url: "https://www.devontechnologies.com/apps/devonthink/pricing"
  - title: "DEVONthink editions"
    url: "https://www.devontechnologies.com/apps/devonthink/editions"
  - title: "DEVONthink release notes"
    url: "https://www.devontechnologies.com/apps/devonthink/releases"
  - title: "DEVONthink To Go"
    url: "https://www.devontechnologies.com/apps/devonthinktogo"
  - title: "DEVONtechnologies blog: Scan in DEVONthink To Go"
    url: "https://www.devontechnologies.com/blog/20260609-scan-in-devonthink-to-go"
  - title: "DEVONtechnologies blog: DEVONthink sync"
    url: "https://www.devontechnologies.com/blog/20220628-devonthink-sync"
  - title: "DEVONtechnologies community blog: Discovering DEVONthink 4, handling email"
    url: "https://discourse.devontechnologies.com/t/discovering-devonthink-4-handling-email/84726"
  - title: "DEVONthink 3.8.2 help: The File menu"
    url: "https://download.devontechnologies.com/download/devonthink/3.8.2/DEVONthink.help/Contents/Resources/pgs/menus-file.html"
  - title: "Cloudflare Workers pricing"
    url: "https://developers.cloudflare.com/workers/platform/pricing/"
---

## Different tools for overlapping jobs

DEVONthink is a document and knowledge database for the Mac. It keeps documents in databases on your Mac and gives you tools to annotate, link, tag, and script them. It is a general tool, and paperwork is one thing you can keep in it.

Schublade does one job. It is an archive for a household's letters, bills, and receipts. It runs as one Cloudflare Worker on your own Cloudflare account. A language model on Workers AI reads each document and gives it a title, a date, a sender, a category, and the household member it belongs to. Everyone in the household signs in from a browser and sees the same archive.

## Who each one suits

Schublade suits a household where more than one person deals with paper, and where nobody wants to sort it. You forward an email, photograph a letter, or post a file with a token, and the document is filed and searchable a few minutes later. Search works on meaning as well as keywords and across languages. Read more on the [web app page](/web/).

DEVONthink suits a Mac user who wants to organize documents by hand and with help. Its See Also and Classify features suggest where a document belongs, and it has smart groups and smart rules. With the Pro edition, a generative model can tag and summarize. It is also a research tool, with annotations, newsfeeds, a reading list, and scripting.

## Where DEVONthink is clearly ahead

- **Offline and local.** DEVONthink keeps its databases on your Mac. Schublade needs a network connection and a Cloudflare account on the Workers Paid plan.
- **Apps you can install today.** DEVONthink for Mac and DEVONthink To Go for iPhone and iPad are available now. Schublade's [iPhone app](/iphone/) and [Mac app](/mac/) work, but they are not released yet.
- **Depth.** Annotations, scripting, smart rules, and a choice of online or local AI models go far beyond what Schublade offers. Schublade has no annotations, and you revise a document's details in the browser.
- **Pricing model.** DEVONthink is a one-time purchase with one year of updates. Schublade costs a monthly Cloudflare plan plus a small amount per document.
- **Maturity.** DEVONthink is a commercial product in its fourth major version. Schublade is a young open source project.

## Where Schublade differs

Schublade files every document without rules or training. The fields it extracts, such as amounts and IBANs, appear next to the original, and you can correct them in the browser.

Schublade receives mail itself. You forward a message to an address on your Cloudflare domain, from any device. DEVONthink archives messages from Apple Mail or Outlook on your Mac, so the Mac does the import.

Schublade is built for a household. One deployment serves one household, and Cloudflare Access controls who may sign in. Every person sees every document, so no document is private to one person. DEVONthink gives each Mac its own databases, and sharing them with another person means sync or the Server edition.

Both connect to AI assistants through MCP. Schublade's connector gives Claude or another client four read-only tools, and the consent page can limit a connection to the categories, senders, and tags you choose.

## Moving from DEVONthink to Schublade

1. In DEVONthink, select the documents and choose **File > Export > Files and Folders**. DEVONthink writes them in their native format and keeps your groups as Finder folders.
2. Deploy Schublade with `pnpm run provision` on your Cloudflare account.
3. Send the exported files. Upload them in the browser, 20 files at a time, or issue a token under **Settings** and post them from a script to `/api/documents/ingest`. When the Mac app is released, its collector can watch the export folder and send only the files the archive lacks.

Schublade accepts PDF, JPEG, PNG, and WebP. Anything else stays in DEVONthink. Your groups, tags, and annotations do not carry over, because Schublade classifies each document again. Schublade recognizes a file by the SHA-256 of its bytes, so you can repeat an interrupted upload without creating duplicates.
