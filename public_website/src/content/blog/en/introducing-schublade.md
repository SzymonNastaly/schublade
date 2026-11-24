---
title: "Introducing Schublade, a document archive you host yourself"
description: "Schublade files and indexes a household's letters, receipts, and PDFs on your own Cloudflare account. What it does, who it suits, and what it costs."
publishedOn: 2026-11-20
translationKey: introducing-schublade
tags: ["announcement", "self-hosting"]
---

Schublade is German for "drawer". It is the drawer where a household keeps its paperwork, and it lives on a Cloudflare account that you own. You upload a PDF, forward an email, or photograph a letter. Schublade reads the document, gives it a title, a date, a sender, a category, and a person, and makes its text searchable. You type no tags and pick no folders.

This post explains what Schublade does today, the three ways to use it, who it is for, and what it costs to run.

## What happens to a document

Every document goes through the same steps, whichever way it arrives.

1. Schublade stores the original file in R2, Cloudflare's object storage, on your account.
2. It takes the text of each page. A PDF with a readable text layer gives its text directly. A scanned page or a photograph goes to Moondream 3.1, a vision model on Workers AI, which transcribes it.
3. A language model on Workers AI classifies the document. It writes a title and picks the date, the sender, the category, and the household member it concerns. It also extracts fields such as amounts and IBANs.
4. The text goes into an AI Search index, which combines keyword and semantic search. A search for a word in one language can find a letter written in another.

The standard categories are Invoice, Receipt, Contract, Insurance, Tax Notice, Bank Statement, Medical, and Official Identification. The model can only name a person who is a member of your household, or the household as a whole, so it cannot invent one.

If Schublade cannot open a file or read a page, the document appears under Failed documents. You retry it or delete it there.

## Four ways in

Schublade accepts PDF, JPEG, PNG, and WebP files. One upload takes up to 20 files, 25 MB per file, and 50 MB in total.

- **The browser.** Drag files into the archive. On a phone, add Schublade to the home screen and use the camera.
- **Email.** Forward a message from an allowed address to the address you set up. Schublade archives the attachments. Schublade prints a message without one to a PDF and archives that.
- **A scanner, script, or Shortcut.** Issue a token in Settings and post files to the archive. Any program that can send a multipart form works.
- **A folder on your Mac.** The Mac app watches folders you choose and sends only the files the archive does not hold yet.

Schublade keeps one document per file. Send the same bytes twice, from any of these paths, and the second upload answers with the document that already holds them. [How Schublade keeps one document per file](/blog/one-file-one-document/) explains how.

## Three apps

### The web app

The [web app](/web/) is available now. You deploy it to your own Cloudflare account with one command, and it is the full archive. It lists and filters documents by sender, category, person, and tag. It searches, shows the original beside its extracted text and details, and lets you correct those details. It retries failed documents, renames and merges senders and categories, and issues tokens. Open browsers update live when a new document arrives.

### The iPhone app

The [iPhone app](/iphone/) is coming soon. It works today, and it is not yet in the App Store. It replaces a separate scanner app. You tap Scan, the system's document camera finds the page and straightens it, and Save sends the pages to the archive as one PDF. You do not name the scan or choose a folder, because the archive does that. Schublade also appears in the share sheet of Mail, Files, Safari, and Photos. Uploads continue in the background, so a scan taken without a network reaches the archive later.

The app keeps a copy of the archive's records on the phone. You browse, search, and read documents from that copy, also offline.

### The Mac app

The [Mac app](/mac/) is coming soon as well. It has two parts. The collector watches folders such as Downloads or a scanner's output folder. When you add a folder, it counts what the folder holds and what the archive lacks, and it asks before it sends the backlog. After that it sends new files on its own. The library is a native window with a list, a reader, and an inspector, built on a local copy, so search answers on every keystroke and works on a train.

Editing, deleting, and token management stay in the browser on both native apps.

## Who it is for

Schublade suits a household that wants its paperwork in one place and searchable, and that is willing to run it on its own Cloudflare account. One deployment serves one household. Everyone who can sign in sees every document. Sign-in goes through Cloudflare Access, and the Worker refuses every browser request without a valid Access sign-in.

It suits people who would rather not hand their bank statements and medical letters to a document service run by someone else. The files, the database, the search index, and the model calls all stay on your account. You need no API key from a third-party model provider.

It does not suit a team that needs separate permissions per person inside one archive. It also does not suit someone who wants an app to install and forget. Somebody in the household has to deploy it and keep the Cloudflare account in order.

You can also connect an AI assistant such as Claude. Add your archive's `/mcp` address as a connector, and a consent page lets you allow the whole archive or only chosen categories, senders, and tags. The assistant gets four read-only tools to search, list, and read documents.

## What it costs

Schublade needs the Workers Paid plan. Cloudflare charges [a minimum of 5 USD a month per account](https://developers.cloudflare.com/workers/platform/pricing/) for it. Workers Free is a goal, but rendering a scanned page today takes more CPU time than the 10 ms the free plan allows. Sign-in needs Cloudflare Zero Trust, whose free plan covers 50 users.

Cloudflare bills the model calls per use. Classifying a document costs about 0.0023 USD. Each page that needs text recognition costs about 0.0008 USD more. A PDF with a readable text layer skips recognition.

As an example, take 100 documents a month, half of them one-page photographs. That is about 0.23 USD for classification and 0.04 USD for recognition, so well under one dollar on top of the plan. This is arithmetic from the per-document figures, not a measured bill. Cloudflare bills storage and search under its own pricing for R2 and AI Search, and the total depends on how much you keep.

## Where to start

The source is on [GitHub](https://github.com/SzymonNastaly/schublade). The [web app page](/web/) walks through the deployment. If you want to know why Schublade runs on your own account, read [why your document archive should run on an account you own](/blog/document-archive-on-your-own-account/). If you want to see how it reads a crumpled receipt, read [how Schublade reads a photographed receipt](/blog/how-schublade-reads-a-photographed-receipt/).
