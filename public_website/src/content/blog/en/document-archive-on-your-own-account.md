---
title: "Why your document archive should run on an account you own"
description: "Bank statements, contracts, and medical letters say a lot about a household. Why Schublade runs on your own Cloudflare account, and what that costs you."
publishedOn: 2026-11-21
translationKey: own-account
tags: ["self-hosting", "privacy"]
---

A household's paperwork is a detailed record of its life. Bank statements show where the money goes. Payslips show what comes in. Insurance letters, medical invoices, a rental contract, and a tax assessment fill in the rest. Whoever holds that drawer knows a great deal about you.

Schublade is built so that you hold it. It runs as one Cloudflare Worker on a Cloudflare account that you own, and every part of it stays there. This post explains what that means in practice and where the design costs you something.

## What stays on your account

Each job in Schublade runs on a Cloudflare service in your account.

| What                                 | Where it lives             |
| ------------------------------------ | -------------------------- |
| Original files and extracted text    | R2                         |
| Records such as titles and senders   | D1                         |
| The search index                     | AI Search                  |
| Reading scanned pages and photos     | Images and Moondream 3.1 on Workers AI |
| Classification                       | DeepSeek V4.1 Flash on Workers AI, through AI Gateway |
| Sign-in                              | Cloudflare Access          |

The models run on Workers AI under your account. You need no API key from a third-party model provider, and Schublade sends your documents to no service outside your Cloudflare account. Nobody else runs a Schublade server that sees your files, because there is no such server. You deploy the code yourself, and the source is on [GitHub](https://github.com/SzymonNastaly/schublade) for you to read.

That leaves one company in the picture, Cloudflare, which runs the infrastructure. You trust Cloudflare with the data the way you would trust any host. You do not also trust a document service on top of it.

## Who can see what

One deployment serves one household. Everyone who can sign in sees every document. Sign-in goes through Cloudflare Access, and you name the email addresses that may sign in when you set Schublade up.

The Worker fails closed. If the Access configuration is missing, it refuses every browser request with 403. It has no demonstration user and no fallback identity.

Anything that is not a person in a browser uses a token, and each token gets the least it needs.

- A token at the `ingest` level is for a scanner, a script, or the Mac collector. It can add documents. It cannot read a title, a text, or an original.
- A token at the `read` level is for the iPhone and Mac apps. It can read the archive and add documents.

Settings issues both and starts with `ingest`. Reading is never the default.

An AI assistant connected over MCP gets four read-only tools. On the consent page you choose whether it sees the whole archive or only some categories, senders, and tags, and Settings lets you disconnect it later.

Email works only from addresses you allow, and only when Cloudflare's own check of the message reports `dmarc=pass` for the sender's domain. Before Schublade prints a message to PDF, it removes scripts, frames, and refresh tags from the markup.

## What it costs

Schublade has no subscription of its own. You pay Cloudflare for what the deployment uses.

- The Workers Paid plan, which Cloudflare bills at [a minimum of 5 USD a month per account](https://developers.cloudflare.com/workers/platform/pricing/).
- About 0.0023 USD to classify each document.
- About 0.0008 USD for each page that needs text recognition. A PDF with a readable text layer skips this step.
- Storage in R2 and queries to AI Search, billed under Cloudflare's pricing for those products.

For most households the model calls stay small. Fifty one-page photographs a month cost about 0.12 USD to classify and 0.04 USD to read, by the per-document figures above. That is arithmetic, not a measured bill.

## The trade-offs

Running on your own account has real downsides. You should know them before you start.

### You need a paid plan

Schublade does not run on Workers Free today. Rendering a scanned page takes more CPU time than the 10 ms the free plan allows. Workers Free is a goal, but it is not tested on a real free account yet. Until then the 5 USD minimum is the floor of what Schublade costs you.

### You depend on Cloudflare

Every part of Schublade uses a Cloudflare product. D1, R2, Workflows, AI Search, Workers AI, Images, Browser Run, Email Routing, Durable Objects, and Access all have to be available on your account. Schublade does not run on another cloud or on a server at home. If you leave Cloudflare, you leave Schublade too.

### You are the operator

Somebody in the household deploys Schublade from a terminal with Node.js and pnpm. The provisioning script creates the database, the storage, the search index, and the sign-in rules, and you can run it again safely. Later code changes need `pnpm run deploy`. Nobody else watches your deployment for you.

### One household, one archive

Everyone who signs in sees every document. Schublade has no per-person permissions inside one archive. That is the intended design for a family or a shared flat that files paper together. It does not fit a group that needs to hide documents from each other. Two households need two deployments.

### Search is not instant

AI Search indexes a new document after it is archived. On the development instance, indexing took 73 to 145 seconds when 12 uploads arrived together. A letter you archived a moment ago may not show up in a text search yet. The list and the filters show it at once.

## When a hosted service is the better choice

If nobody in your household wants to touch a terminal, a hosted document service will serve you better. If you need an archive shared across several households with separate rights, Schublade is the wrong tool.

If you are comfortable with one Cloudflare account and want your paperwork to stay in it, Schublade gives you a searchable archive without handing the drawer to anyone else. [Introducing Schublade](/blog/introducing-schublade/) covers what it does, and the [web app page](/web/) covers the deployment.
