---
title: "Schublade vs Google Drive for household paperwork"
description: "Keeping household paperwork in Google Drive? Compare it with Schublade on filing, text recognition, search, email intake, apps, sharing, and cost."
competitor: "Google Drive"
competitorUrl: "https://drive.google.com/"
verifiedOn: 2026-11-24
summary: "Choose Schublade if you want paperwork filed and named for you, in an archive on your own Cloudflare account that the household can search by meaning. Choose Google Drive if you want free storage with nothing to set up, apps on every device today, and room for every kind of file."
aspects:
  - aspect: "Where it runs"
    schublade: "One Cloudflare Worker on your own Cloudflare account, used in any browser."
    competitor: "Google's service, used through drive.google.com and Google's apps."
  - aspect: "Who maintains it"
    schublade: "Cloudflare runs the platform. You deploy it once and deploy new versions with one command."
    competitor: "Google. You create an account and start."
  - aspect: "Text recognition"
    schublade: "Schublade reads every scan and photo on arrival. A readable PDF text layer is used as it is, and other pages go to the Moondream 3.1 vision model."
    competitor: "The iPhone app saves scans as searchable PDFs. A PDF or picture up to 2 MB can be converted to a Google Doc with its text."
  - aspect: "Filing"
    schublade: "A language model sets title, date, sender, category, and household member, and extracts amounts and IBANs."
    competitor: "You choose the folder and the file name. The iPhone scanner suggests a title."
  - aspect: "Search"
    schublade: "Keyword and semantic search across languages, plus filters for sender, category, and tag."
    competitor: "Search by name and text with filters for type, people, and date. With Gemini, you can ask in natural language."
  - aspect: "Email intake"
    schublade: "Forward mail from an allowed address to your archive's address. Schublade prints a message without an attachment to a PDF."
    competitor: "In Gmail, you add each attachment to Drive by hand with Add to Drive."
  - aspect: "Phone app"
    schublade: "iPhone app with a document scanner, the share sheet, and an offline copy, coming soon. The web app works on a phone today."
    competitor: "Google Drive app for iPhone with a built-in document scanner, available now."
  - aspect: "Mac app"
    schublade: "Mac app with a reader, an offline copy, and a collector for chosen folders, coming soon."
    competitor: "Drive for desktop shows Drive in Finder and streams or mirrors your files."
  - aspect: "Sharing within a household"
    schublade: "One household per deployment. Everyone who can sign in sees every document."
    competitor: "Share files and folders as viewer, commenter, or editor. Paid storage can be shared with up to five other people."
  - aspect: "Data location"
    schublade: "Your Cloudflare account, with files in R2 and records in D1. Recognition and classification run on Workers AI in the same account."
    competitor: "Google's servers, under your Google account."
  - aspect: "AI assistant access (MCP)"
    schublade: "Built-in MCP connector with four read-only tools. The consent page can limit it to chosen categories, senders, and tags."
    competitor: "A remote Drive MCP server in Google's Workspace Developer Preview Program. It needs a Google Cloud project and an OAuth client, and its tools can also create files."
  - aspect: "Cost"
    schublade: "Cloudflare Workers Paid plan, at least 5 USD a month (Cloudflare's pricing page, read 2026-11-24), plus about 0.0023 USD per document and 0.0008 USD per recognized page."
    competitor: "15 GB free. Google One Basic with 100 GB costs 1.99 EUR a month (Google One plans page, shown in euros, read 2026-11-24)."
sources:
  - title: "Google One plans"
    url: "https://one.google.com/about/plans"
  - title: "Google Drive Help: Convert PDF and photo files to text"
    url: "https://support.google.com/drive/answer/176692"
  - title: "Google Drive Help: Search for files in Google Drive"
    url: "https://support.google.com/drive/answer/2375114"
  - title: "Google Drive Help: Scan documents with Google Drive (iPhone and iPad)"
    url: "https://support.google.com/drive/answer/3145835?hl=en&co=GENIE.Platform%3DiOS"
  - title: "Google Drive Help: Get updates and summaries on your files with Gemini in Drive"
    url: "https://support.google.com/drive/answer/16686465?hl=en"
  - title: "Google Drive Help: Collaborate with Gemini in Google Drive"
    url: "https://support.google.com/drive/answer/14356148?hl=en"
  - title: "Google Drive Help: Use Drive for desktop on macOS"
    url: "https://support.google.com/drive/answer/12178485?hl=en"
  - title: "Google Drive Help: Share and manage access to files and folders"
    url: "https://support.google.com/drive/answer/2494822?hl=en"
  - title: "Gmail Help: Open and download attachments"
    url: "https://support.google.com/mail/answer/30719?hl=en&co=GENIE.Platform%3DDesktop"
  - title: "Google for Developers: Configure the Drive MCP server"
    url: "https://developers.google.com/workspace/drive/api/guides/configure-mcp-server"
  - title: "Cloudflare Workers pricing"
    url: "https://developers.cloudflare.com/workers/platform/pricing/"
---

## A folder of files or an archive that files itself

Keeping paperwork in a cloud drive is simple. You scan a letter with the phone, give it a name, and put it in a folder. That works until you need the one letter from three years ago and cannot remember what you called it.

Google Drive is general file storage. It holds any file, it syncs to your devices, and it lets you share files and folders with other people. Organizing is up to you. The Drive app on the iPhone scans paper into searchable PDFs, and you pick the name and the folder.

Schublade is an archive built only for paperwork. It runs as one Cloudflare Worker on your own Cloudflare account. A language model on Workers AI reads each document and gives it a title, a date, a sender, a category, and the household member it belongs to. It also extracts fields such as amounts and IBANs. You never name a file or pick a folder.

## Who each one suits

Schublade suits a household that wants letters, bills, and receipts filed without effort and found again by meaning. Search matches meaning as well as keywords, and it works across languages. You can forward an invoice by email, and Schublade files it. Read more on the [web app page](/web/).

Google Drive suits people who want storage with nothing to set up, for every kind of file. Its apps run on your phone and your computer today. If you already pay for Google storage, your paperwork costs nothing extra there.

## Where Google Drive is clearly ahead

- **No setup and a free tier.** Every Google account comes with 15 GB of storage. Schublade needs a Cloudflare account on the Workers Paid plan, a deployment from the command line, and billing per document.
- **Apps today.** Drive has an iPhone app with a scanner and Drive for desktop on the Mac. Schublade's [iPhone app](/iphone/) and [Mac app](/mac/) work, but they are not released yet.
- **Any file.** Drive stores documents, images, audio, and video. Schublade accepts PDF, JPEG, PNG, and WebP.
- **Sharing with control.** Drive lets you share one file or folder as viewer, commenter, or editor. Schublade serves one household per deployment, and everyone who signs in sees every document.
- **Maturity.** Schublade is a young open source project.

## Where Schublade differs

Schublade reads every page on arrival. A PDF with a readable text layer keeps that text. A scan or a photo goes to a vision model that also handles pages photographed sideways. In Drive, the scanner makes searchable PDFs, but converting an uploaded picture to text is a separate step for files up to 2 MB.

Your files stay in your own Cloudflare account. Recognition and classification run on Workers AI in that account, so no other model provider sees your documents, and you need no API key.

Email intake is built in. You forward a message from an allowed address to an address on your Cloudflare domain, and Schublade archives the attachments. In Gmail, saving an attachment to Drive is a click on each file.

Schublade has a built-in MCP connector for Claude and other MCP clients. Its four tools only read, and the consent page can limit a connection to the categories, senders, and tags you choose. Google offers a Drive MCP server in a developer preview, which needs a Google Cloud project and an OAuth client, and whose tools can also create and copy files.

## Moving from Google Drive to Schublade

1. Deploy Schublade with `pnpm run provision` on your Cloudflare account.
2. Get your paperwork onto your computer. Drive for desktop can mirror My Drive, which keeps a full copy of your files in a folder on the Mac.
3. Send the files to Schublade. Upload them in the browser, 20 files at a time, or issue a token under **Settings** and post them from a script to `/api/documents/ingest`. When the Mac app is released, its collector can watch the mirrored folder and send only the files the archive lacks.

Your folders do not carry over, and Schublade gives each document its own title. Files other than PDF, JPEG, PNG, and WebP stay in Drive. Schublade recognizes a file by the SHA-256 of its bytes, so a document that sits in two Drive folders becomes one document in the archive, and you can repeat an interrupted upload safely.
