---
title: "How Schublade keeps one document per file"
description: "Schublade names every file by the SHA-256 of its bytes. What happens when you upload the same file twice, delete it, or let the Mac collector send a folder."
publishedOn: 2026-11-23
translationKey: content-identity
tags: ["engineering", "duplicates"]
---

A household archive collects duplicates without trying. The same invoice arrives as an email attachment and again in the Downloads folder. A PDF gets copied from the desktop into a scans folder. Someone uploads a statement that someone else forwarded last week. A naive archive files each copy as a new document, and the list fills with twins.

Schublade keeps one document per file, whichever way the file arrives. This post explains how it decides that two files are the same, what happens on a second upload and after a deletion, and how the Mac collector uses the same rule to send only what the archive lacks.

## A file is its bytes

Schublade computes the SHA-256 digest of every file it receives. SHA-256 turns any sequence of bytes into a 64-character fingerprint. Two files with the same bytes have the same fingerprint, and two files that differ in a single byte get different ones.

Schublade calls such a byte sequence a content. A table in the database names every content the archive has received and the document that holds it. Each document records the digest of the original it shows.

Identity is the bytes alone. The file name, the folder, and the date do not count. That has two consequences.

- A renamed or moved copy is the same file. `Rechnung.pdf` in Downloads and `invoice_october.pdf` in Documents are one document if their bytes match.
- Another scan of the same letter is a new file. A scanner never produces the same bytes twice, so two scans of one page are two documents. Schublade does not guess that two different files show the same paper.

## The second upload

Every way into the archive passes through the same rule. That includes the browser, a token from a script or Shortcut, an email attachment, and the Mac collector. Before Schublade writes anything, it computes the digest and looks it up. If a document already holds those bytes, the upload answers `already_archived` with that document, and the upload panel says the file is already in the archive. Schublade does not classify the file again, and you pay for nothing twice.

Two uploads of the same new file can arrive at the same moment, for example from two phones. Schublade writes the new document row and the claim on the content in one database batch, which D1 runs as one transaction, and then reads the claim back. The upload that lost removes its own row and answers with the winner's document. The archive ends up with one document either way.

Schublade prints an email without a usable attachment to a PDF. The printing step computes the digest of that PDF and claims it under the same rule.

## After a deletion

Deleting a document leaves a choice. The archive can forget the file, or it can remember that you deleted it.

Schublade remembers. The content stays in its table, with no document attached. What happens next depends on who sends the bytes again.

- **A person.** If you upload the file again in the browser, forward it again, or send it with a token, Schublade archives it again. You chose to send it, so it comes back.
- **The collector.** A program that watches folders should never bring back a document you deleted, just because the file still sits in a folder. The collector's upload route answers `409` for deleted content before it reads the file, and the lookup answers `deleted`.

The iPhone app counts as a person. A scan or a shared file goes through the same route as a browser upload, because whoever scans a letter chose to send it.

## How the Mac collector uses this

The collector in the [Mac app](/mac/) watches folders that you choose. It needs to know which files the archive already has, and it should not upload a 20 MB PDF to find out. The digest lets it ask first.

1. The collector reads a file once and computes its SHA-256.
2. It sends up to 1000 digests in one request to `POST /api/v1/contents/lookup`. The archive answers each one with `absent`, `present` and the document's identifier, or `deleted`.
3. It uploads only the files whose answer is `absent`, one file per request to `PUT /api/v1/contents/<digest>`. The archive answers `202` for a new document and `200` for one it already holds. If the bytes do not match the digest in the address, it answers `422`.

Because everything keys on the digest, the awkward cases need no special handling.

- **The same file in two folders** is one content. The collector sends it once.
- **A rename or a move** inside the watched folders changes the path and leaves the content. Nothing is sent again.
- **A file you edit** becomes a new content. The collector looks it up and sends it. The old version stays in the archive.
- **A file you delete on the Mac** stays in the archive. The collector has no request that deletes.
- **A lost state database** costs one new survey. The collector reads every file again, and the lookup answers `present` for everything the archive already holds, so nothing is sent twice.

When you add a folder, the collector first surveys it. It reads and looks up every file and shows how many the archive lacks, and only then asks whether to send that backlog. You can say no, and those files are never sent, while new files in the folder still are.

The collector uses a token at the `ingest` level. That token can add documents and look up digests. It cannot read a title, a text, or an original.

## Older archives

Content identity arrived after the first documents were archived. An archive from before that change computes the digests of its older documents in the background, 25 every 15 minutes. Until every document has its digest, the collector's lookup and upload answer `503` with a `Retry-After` header. Otherwise the lookup would call an old document `absent`, and the collector would archive it a second time.

## What this does not catch

The rule is exact, and that is its limit. Two scans of one letter, a PDF and a photo of the same receipt, or an invoice the sender emailed twice with a new timestamp inside are different bytes and become different documents. Schublade files and classifies each one. Telling them apart is your call, in the archive.

To start collecting, see the [Mac app page](/mac/). The Mac app is coming soon. Tokens and scripts work today with the [web app](/web/). For an overview of every way in, read [Introducing Schublade](/blog/introducing-schublade/).
