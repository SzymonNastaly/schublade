# Client preprocessing design

How the text and the first-page picture of a document move from the Worker to the clients, drafted on 2026-11-26. It extends `notes/client_protocol.md` with two routes and changes one premise of `notes/iphone_application_design.md`, which says "The PDF carries no text layer: the archive reads its pages as it reads every scan". The owner decided its open questions on 2026-11-26, and units S1, S2, S3, C1, C4, C5, and M1 are built, and the Rust part of C3.

Every claim about behaviour carries one of three labels. Documented means a vendor's documentation or this repository's notes say it. Measured means someone ran it, with the date. Inferred means it follows from the other two and nobody ran it.

## Problem

The Worker does work per byte and per page for every document. It buffers the upload, parses multipart, computes the SHA-256 (0.8 ms per MiB, measured), opens the PDF in PDFium, renders pages for Moondream, and draws thumbnails. Workers Free allows 10 ms of CPU per request (documented), so a scan of a few megabytes cannot fit, and Paid pays for work that every client can do for nothing.

Each client already holds the file and a PDF library. The client extractors recover at least 99.8% of PDFium's text on the test documents, and Vision in German found every expected value on the scanned fixtures and a receipt photograph (measured, 2026-11-25). So the client reads the text and draws the picture, and the Worker stores what arrives.

The constraints that shape the design:

- The iPhone uploads from a background `URLSession`, which sends one request per upload from one file (documented). The share extension ends right after Send, so it cannot order several requests.
- The rules of content identity stay: `already_archived`, the 409 for a content the owner deleted, and the 503 while a digest is missing (`AGENTS.md`, "A content is the SHA-256 of a file's bytes").
- R2 rejects a stream of unknown length (the comment in `acceptDocumentUpload`), and `put(key, body, { sha256 })` verifies the digest on R2's side (documented).
- An application from the App Store updates on its own, and a household updates its archive when it chooses. A new build meets an old archive, and an old build meets a new archive.
- Mail has no client.

## What each client sends

| Client | Text | Thumbnail | Route |
| --- | --- | --- | --- |
| iPhone application and share extension | PDFKit's text layer, Vision for a page without one and for a picture | The first page, drawn as today by `SubmissionPicture` | `PUT /api/v1/submitted_documents/{sha256}` |
| Mac application's collector | The same Swift module, called from the collector | The same | `PUT /api/v1/collected_documents/{sha256}` |
| `schublade-collector` on Linux and macOS | The text layer through pdfium-render, no recognition | The first page through pdfium-render | `PUT /api/v1/collected_documents/{sha256}` |
| Web application | PDF.js `getTextContent()`, nothing for a picture or a scanned page | The first page or the picture on a canvas | `PUT /api/submitted_documents/{sha256}`, behind Access |
| A script or a Shortcut | None | None | The same route as the iPhone with a plain body. `POST /api/documents/ingest` until unit L1 removes it (decision 4) |
| Mail | None. The Worker reads it, see [Mail](#mail) | None for an attachment | No route |

One request from a script, with no derived representation:

```bash
curl -T scan.pdf -H "Authorization: Bearer $TOKEN" \
	"https://archive.example.org/api/v1/submitted_documents/$(sha256sum scan.pdf | cut -d' ' -f1)"
```

One request from an application, with both:

```http
PUT /api/v1/submitted_documents/a3f1c2d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90 HTTP/1.1
Authorization: Bearer schublade_…
Content-Length: 1869412
Schublade-Text-Byte-Count: 4180
Schublade-Thumbnail-Byte-Count: 21999
Schublade-Page-Count: 3

<4,180 bytes of Markdown><21,999 bytes of JPEG><1,843,233 bytes of the original>
```

`202` for a new document and `200` for a content a document holds already, both with the body and the `Location` of the document status route:

```json
{ "document_id": "4d1f0c9e-2a6b-4c3e-9a51-0b7f6e2d8c11", "status": "processing", "failure_reason": null }
```

## Shape

### One request with a counted prefix

The body is the text, then the thumbnail, then the original, with no separator. Two headers give the byte counts of the first two, and each defaults to 0. The original is everything after them, so its length is `Content-Length` minus both counts. A request without the headers is the original alone.

The Worker reads exactly the counted bytes and the first 12 bytes of the original from `request.body` with a BYOB reader (`readAtLeast`). It identifies the kind of file from those 12 bytes with `identifySourceFile`, as today. Then it writes the 12 bytes into a `FixedLengthStream` of the original's length, pipes the rest of the body into it, and hands the readable side to `DOCUMENT_STORAGE.put` with `{ sha256 }` from the path. No JavaScript touches the original after its 12th byte, and nothing hashes it in the Worker.

Measured on 2026-11-26 in workerd 1.20261104.1 through miniflare, over HTTP, with a 24 MB original after a 31-byte prefix (the probe is `stream_probe/probe.mjs` in the session's scratchpad, not in the repository):

- `put(key, request.body, { sha256 })` on an untouched body stores the object and records the digest.
- After a BYOB read of a prefix, `put(key, request.body)` fails with "This ReadableStream is disturbed.". The `FixedLengthStream` is therefore required, not a choice.
- The prefix read, the 12 leading bytes written back, and the rest piped through the `FixedLengthStream` store the right 24,000,005 bytes with the right digest.
- A wrong digest and a truncated original both fail with "put: The SHA-256 checksum you specified did not match what we received. … (10037)", and no object is stored.
- When the Worker answered before it read a 20 MB body, a Node client lost the connection with `EPIPE`. A 5 MB body got its answer. See risk 1.

Deployed R2 answers a mismatch with the same message and code (measured on staging, 2026-11-26): "put: The SHA-256 checksum you specified did not match what we received. You provided a SHA-256 checksum with value: … Actual SHA-256 was: … (10037)". The reception logs it as "R2 refused the original of <sha256>". A put that fails for any other reason answers 500, and a client sends both again later, so a wrong reading of the error costs a wrong status code and no data.

### Why not multipart, and why not several requests

Multipart needs a scan for the boundary. `request.formData()` buffers the whole body, and R2 still needs a length for the file part. A hand-written parser that streams the last part works only when the client promises the order and the lengths, which is the counted prefix with more ways to be wrong.

Several requests, such as `PUT …/text` and `PUT …/thumbnail` by digest before the original, need a place for representations whose original has not arrived, a sweep for those whose original never arrives, three passes through the token check, and an order the iPhone's share extension cannot guarantee. With one request the Workflow starts after all three objects are stored, so it never races the text.

### The routes

`src/client_protocol/client_paths.ts` gains one entry whose pattern matches two paths:

| Method | Path | Level | Restricted scope | Who sends it |
| --- | --- | --- | --- | --- |
| PUT | `/api/v1/submitted_documents/{sha256}` | ingest | refused | A person: the iPhone application, its share extension, a script |
| PUT | `/api/v1/collected_documents/{sha256}` | ingest | refused | A collector: the Mac application and `schublade-collector` |

```ts
type ClientRoute =
	// …the six kinds of today
	| { kind: "document_reception"; origin: "person" | "collector"; sha256: string }

{
	method: "PUT",
	level: "ingest",
	restrictedScope: "refused",
	pattern: new RegExp(`^${CLIENT_PATH_PREFIX}/(submitted|collected)_documents/(${DIGEST})$`),
	route: ([, origin, sha256 = ""]) => ({ kind: "document_reception", origin: origin === "collected" ? "collector" : "person", sha256 }),
}
```

The two paths differ only in the rules a collector must obey. A collector must never bring back a document the owner deleted, and it must wait while a digest is missing, so `collected_documents` answers 409 and 503 as `PUT /api/v1/contents/{sha256}` does. A person chose to send, so `submitted_documents` archives a deleted content again and never answers 503, as `POST /api/documents/ingest` does today. The origin is part of the path, so no request can leave it out.

The web application reaches the same function at `PUT /api/submitted_documents/{sha256}` behind Access. `request_dispatch.ts` matches that one anchored pattern inside `serveMember`, next to the archive changes socket and the consent page, so the body reaches the function as the stream workerd made and TanStack Start never wraps it. When the web application becomes a static client with a token, it sends the same body to the bearer route.

Both bearer routes sit under `/api/v1`, which Access bypasses already, so no Access application changes. The level is `ingest`, because adding a document exposes nothing. The answer holds an identifier, a status, and a failure reason, so an `ingest` token still reads no title and no text. A restricted token is refused, because the answer names the document that holds the bytes whether or not the scope admits it. The gate's refusal sentence names a collector today, so the route table carries the sentence for each route. `request_dispatch.workerd.test.ts` gets one line per path and level.

The old routes stay for old builds and scripts. See [Versions](#versions).

### The order of checks

After the gate's method, token, level, and scope, `receiveDocument` in the new `src/ingestion/document_reception.ts` answers in this order:

| Status | When |
| --- | --- |
| 503 | `collected_documents` only: a document still awaits its digest. `Retry-After: 900` |
| 409 | `collected_documents` only: the owner deleted the document of this content |
| 400 | A count that is no decimal number, a page count below 1, a query parameter, or no byte left for the original |
| 411 | No `Content-Length` |
| 413 | A text above 2,000,000 bytes, a thumbnail above 200,000 bytes, or an original above 25,000,000 bytes |
| 200 | A document holds the content. Nothing is read past the headers and nothing is written |
| 415 | The thumbnail does not start with `FF D8 FF`, or the original's 12 leading bytes are no PDF, JPEG, PNG, or WebP file |
| 422 | R2 received other bytes than the digest in the path names. Nothing is stored |
| 202 | The content became a new document |

Every check above the 415 reads only headers and D1. `parseReceptionHeaders` is a pure function, tested in Node.

`Content-Type` is not read. The archive identifies a file by its leading bytes, as it does today, so a client may send the original's media type and a wrong one changes nothing.

### What the Worker stores

| R2 key | Written by | Content type |
| --- | --- | --- |
| `documents/{id}/original.{pdf,jpg,png,webp}` | The reception, streamed with `{ sha256 }` | The identified kind |
| `documents/{id}/submitted_text.md` | The reception, when the text count is above 0 | `text/markdown; charset=utf-8` |
| `documents/{id}/thumbnail.jpg` | The reception, when the thumbnail count is above 0 | `image/jpeg` |
| `documents/{id}/content.md` | The Workflow, as today | `text/markdown; charset=utf-8` |
| `documents/{id}/thumbnail.png` | The PDFium drawing of today, until PDFium leaves | `image/png` |

Every key lies under `documentObjectPrefix`, so `deleteDocument`, which lists and deletes that prefix, removes the new objects without a change. `documents.page_count` takes `Schublade-Page-Count` at the insert, and `documents.byte_size` takes the original's length. No migration is needed.

`archiveContent` stays the one rule that archives a content once. Its submission becomes bytes, for multipart and mail, or a stream with a length, for the reception, and it gains the optional derived representations. The lookup, the batch with the document row and the content claim, the reading back of the claim, and the loser's cleanup stay as they are. The loser now removes its three objects.

The text is stored as `submitted_text.md` and not as `content.md`, because `notes/client_protocol.md` promises that a document's text is written once, in the step before `classifying`. The Workflow decides whether the submitted text becomes the text. A retried document reads the submitted text again.

### Retries and races

- A PUT is named by its digest, so sending it again is safe. A retry after a lost 202 answers 200 with the same document.
- Two uploads of one content each stream to their own document prefix. The D1 batch names one holder, and the other removes its objects and its row and answers 200, as today.
- The iPhone application and its share extension can send one submission twice. The second gets 200, which `read_submission_answer` reads as `Archived { already_held: true }`, as today.
- An isolate that ends between the R2 writes and the D1 batch leaves objects that no row lists. That window exists today for the original and now holds three objects. Nothing reads them. Inferred: Workers Free ends more invocations at its limit, so the window is hit more often there.

### What a request costs the Worker

The Worker copies the counted prefix once, at most 2,200,000 bytes and usually a few tens of kilobytes, and does two D1 reads, three R2 writes, one D1 batch, and one Workflow start. The 0.8 ms per MiB of hashing, the multipart parse, the full copy into an `ArrayBuffer`, and the `TransformStream` of `limitRequestBody`, which runs JavaScript for every chunk, are gone from this route.

Measured on staging on 2026-11-26 through `cf o11y telemetry`, with synthetic PDFs and the staging ingest token on `submitted_documents`:

| Request | Status | CPU | Wall |
| --- | --- | --- | --- |
| 20 MB, new content, first request after a deploy | 202 | 23 ms | 1,597 ms |
| The same 20 MB again | 200 | 11 ms, then 2 ms on a later run | 70 ms, 48 ms |
| 20 MB under a wrong digest | 422 | 12 ms, then 13 ms | 695 ms, 643 ms |
| 1 MB with an 80-byte text, first request after a deploy | 202 | 11 ms | 924 ms |

The CPU no longer follows the size: the 1 MB and the 20 MB uploads cost about the same. It is still above the 10 ms of Workers Free for a new content and a mismatch, so what remains is the per-request work around the stream (token, D1, R2 calls, the Workflow start), not the bytes. The old route was not measured, because the same deploy moved it onto the reception. `curl -T` got every answer, the 200 answered before the body was read included, so risk 1 did not appear with curl.

`PUT /api/v1/contents/{sha256}`, the route of collector builds already installed, moves to the same function in unit S1, with both counts refused. Its wire stays the same and its body is no longer buffered or hashed in the Worker.

### The text

The text is UTF-8 Markdown in the form the archive stores today for pages read from a text layer. Every page has a heading and its plain text, in page order:

```markdown
## Page 1

Stadtwerke Talbrück GmbH
Jahresabrechnung Strom 2025-2026

## Page 2

```

- A page without text keeps its heading with nothing under it, so the page numbers stay right. `TextParagraph` in `library_presentation/` reads `## Page N` as a page mark already.
- A client that read no page sends no text, and the archive's own reading applies.
- A text above 2,000,000 bytes is not sent. A PDF that long has a text layer, which `toMarkdown` reads.
- `Schublade-Page-Count` is the number of pages, 1 for a picture. The Worker never counts headings, so a line of a document that reads "## Page 7" changes nothing in the archive.

The rule that decides whether a text layer is good enough moves to the client. `isReadableTextLayer` in `document_text.ts` says a page is readable with at least 40 letters or digits and fewer than one replacement character per ten of them. Each client applies that rule per page. On an Apple device an unreadable page goes to Vision. In the browser and in `schublade-collector` it stays empty.

The 90% rule of `selectPageTextSources` compares the `toMarkdown` section of a page with PDFium's text layer. It stays as long as PDFium does, for a document that arrives without text. It goes with PDFium, because nothing is left to compare the conversion with. A document with a submitted text never calls `toMarkdown`, so the rule does not apply to it.

### The thumbnail

A JPEG of the first page, at most 480 pixels on its longer side, upright, on white, at most 200,000 bytes. The Worker's drawing of today is 331 by 468 pixels for an A4 page at 40 dots per inch, so every list that shows a thumbnail was built for that size. `SubmissionPicture.pixelLimit` rises from 312 to 480. The Worker checks only the three leading bytes and the size, because decoding a picture is the work this design removes.

`GET /api/v1/documents/{id}/thumbnail` and the browser's `/api/documents/{id}/thumbnail` read through `readThumbnail`, which answers the first of these that exists:

1. `thumbnail.jpg`, the submitted picture.
2. `thumbnail.png` without the `unrenderable` mark, a drawing the Worker made earlier.
3. The original, when it is a picture, as today.
4. Until PDFium leaves: the first page drawn by PDFium and stored as `thumbnail.png`, as today.
5. 404 "This document has no thumbnail".

Every client shows a placeholder on that 404 already, a file icon in the browser and `RepresentationPlaceholder` in the applications. The entity tag stays R2's. `notes/client_protocol.md` changes "A PNG of the first page at 40 dots per inch" to "a JPEG or a PNG of the first page".

After PDFium leaves, three kinds of PDF have no thumbnail: one that arrived by mail as an attachment, one sent by a script or an old build, and an old one nobody ever listed. Decision 5 covers the last kind.

### The Workflow

The steps and what changes in each:

| Step | Today | After unit S2 | After PDFium leaves (R1) |
| --- | --- | --- | --- |
| render email | Prints a stored email | Unit M1: two more steps store the page's text and picture, see [Mail](#mail) | Unchanged |
| extract text | PDFium, `toMarkdown`, `selectPageTextSources` | Reads `submitted_text.md` first. With at least 40 letters or digits it is the text, and nothing else runs. Otherwise today's chain | Submitted text, then `toMarkdown`, then failure |
| recognize page N | Moondream on a rendered page | Only for a document without submitted text | Gone for PDFs. Stays for pictures (decision 1) |
| store markdown | Writes `content.md` | Copies `submitted_text.md` to `content.md` as a stream, or writes the assembled text | Unchanged |
| classify document | Takes the text from the step before | Reads `content.md` from R2 | Unchanged |
| archive document | Writes `page_count` from PDFium | Keeps the `page_count` of the reception when one came | Counts the `### Page N` headings of a conversion |
| index document | Unchanged | Unchanged | Unchanged |

The statuses and their order stay. A document with a submitted text passes `processing`, `extracting`, and `classifying`, and never `recognizing_text`.

The classify step reads the text from R2, because a step's output is limited to 1 MiB (documented) and a submitted text can be 2 MB. The check for 40 letters or digits stops at the 40th, so it costs nothing on a real text.

The fallback chain after R1, for a document without a usable submitted text:

1. A PDF goes to `toMarkdown`. A conversion with at least 40 letters or digits is the text. A conversion that answers an error fails the document with `unreadable_file`.
2. A picture goes to Moondream, as today (decision 1).
3. Otherwise the document fails with `unreadable_page`, whose sentence becomes "No text could be read from this document. Send it from the Schublade app on an iPhone or a Mac, which reads scans on the device."

`page_limit_exceeded` is no longer produced after R1. The schema keeps the value for documents that failed with it.

A failed document holds its content, so sending the same bytes again answers 200 and changes nothing. Unit A1 therefore adds one rule: when the holder of the content has failed and the request carries a text, the reception stores the text and the thumbnail under that document and calls `retryDocumentIngestion`. Sending a failed scan again from a device that can read it then repairs it. A request for a content that a document holds may end after the thumbnail, without the original, because the Worker never reads further.

### Mail

Mail keeps its per-byte cost. The email handler parses the message and hashes each attachment in the Worker, and no client can do that for it.

- **An attachment.** A PDF or a picture arrives through `archiveContent` without text. It takes the fallback chain. A PDF with a text layer is read by `toMarkdown`. A scanned PDF from a network scanner fails after R1, and a picture is still read by Moondream. It has no thumbnail.
- **A printed email.** Today PDFium reads the text layer that Chromium wrote. `toMarkdown` cannot replace it. On a forwarded email it kept three header lines and dropped the rest (measured, `AGENTS.md`). The browser that prints the page can also read it. `printMail` makes two more quick actions with the same inert markup: `scrape` of `body`, whose text is what the page shows, and `screenshot`, cut to the top of the page in the proportion of A4 and reduced to 480 pixels. Documented: `cf browser-run quick-action` lists `scrape` and `screenshot` beside `pdf`. Measured in unit M1: the binding takes both, and the scraped text holds every letter and digit of the text layer. Each printed email costs three browser sessions and not one.
- The printed header's words are added by the Worker, as `printedHeaderText` does today. An email of nothing but pictures is archived with its header and the mail context. `selectPrintedMailTextSources` goes.
- The page count of a printed email is unknown without PDFium and stays null, which the protocol allows.
- The digest of the printed PDF is still computed in the Workflow step, on a file the Worker made itself.

### What replaces PDFium and Moondream

| Today in the Worker | Replacement | Where nothing replaces it |
| --- | --- | --- |
| PDFium text layer | PDFKit, PDF.js, pdfium-render on the client. `toMarkdown` for a PDF without a client | None |
| PDFium opening a file to refuse it | `identifySourceFile` at the reception, a `toMarkdown` error in the fallback | A damaged PDF with a submitted text is archived, because its client could read it |
| PDFium thumbnail | The client's JPEG. Browser Run's screenshot for a printed email | A PDF by mail, by script, or from an old build has no thumbnail |
| PDFium page rendering for Moondream | Vision on an iPhone or a Mac | A scanned PDF from the browser, from `schublade-collector`, from a script, or by mail |
| Moondream on a rendered page | Vision | The same four |
| Moondream on a picture | Vision, and Moondream for a picture that arrives without text (decision 1) | None |
| The four rotations of a page that hit the token limit | Vision reads a page at any rotation (inferred, not measured on a turned fixture) | The same |

### Versions

**An old build with a new archive.** `POST /api/documents/ingest` and `PUT /api/v1/contents/{sha256}` stay. The iPhone build 1.0 in the App Store sends multipart to the first, and the Mac build 1.0 sends the second. Their documents arrive without text and take today's chain until R1. After R1 their PDFs with a text layer still archive through `toMarkdown`, and their scans fail with `unreadable_page`. The Worker logs one line per arrival, `Document reception: route=<name> text=<submitted|absent> thumbnail=<submitted|absent>`, so `cf o11y telemetry` shows whether scans without text still arrive before the owner runs R1.

**A new build with an old archive.** An old archive lacks the new routes, so `requireAccess` answers a plain 403, which `notes/client_protocol.md` defines as `RouteUnknown`. A client learns it without sending a document. The gate checks the method first, so `GET /api/v1/submitted_documents/<64 zeros>` answers 405 as a problem document on a new archive and the plain 403 on an old one. `archive_access` gains `read_document_reception`, which sends that request after `read_authorization` at connecting and once a day. The iPhone keeps the answer in its `ConnectedArchive` record, where the share extension reads it. For an old archive the client says "Update your archive" and holds its uploads until the archive offers the route (decision 2). An upload that still meets `RouteUnknown` records it and waits the same way.

**The protocol.** `/api/v1` only gains a route, two optional headers, and a page count, which `notes/client_protocol.md` allows. No `/api/v2` and no Access change is needed.

### What changes in each code base

**Worker.**

- `src/ingestion/document_reception.ts`, new: `parseReceptionHeaders`, `receiveDocument(environment, database, request, { origin, sha256 })`.
- `src/ingestion/document_upload.ts`: `ContentSubmission.content` becomes bytes or a stream with its length, and `archiveContent` takes the derived representations. `receiveDocumentUploads` stays for the ingest route.
- `src/ingestion/source_file.ts`: `submittedTextObjectKey`, `submittedThumbnailObjectKey`.
- `src/client_protocol/client_paths.ts` and `client_requests.ts`: the entry above. `collection_requests.ts`: `serveContentSubmission` calls `receiveDocument`.
- `src/request_dispatch.ts`: the member's path.
- `src/ingestion/document_ingestion.ts`: the extract text and classify steps.
- `src/archive/document_representation.ts`: the order of `readThumbnail`.
- Removed in R1: `src/inference/page_rasterizer.ts`, `@embedpdf/pdfium`, `selectPageTextSources`, `recognitionLimitViolation`, and the PDF branch of `readPage`.

**Rust.**

- `archive_access/src/document_submission.rs`: `prepare_submission` takes `&DerivedRepresentations { page_texts: Vec<String>, thumbnail: Option<PathBuf> }` and a `SubmissionRoute`, and writes the prefix and the original to the body file. `PreparedSubmission` becomes `{ url, method, headers: Vec<(String, String)>, body_bytes }`, so Swift sets whatever headers Rust names. `compose_document_text(&[String]) -> String` writes the page headings. `read_submission_answer` reads the status body and a problem document, and gains `SubmissionAnswer::RouteUnknown`. The multipart writer goes once no client calls it (decision 2).
- `archive_access/src/archive_exchange.rs`: `put_document(path, headers, parts: &[&[u8]])`, which sends the parts one after another without joining them.
- `collection_core/src/document_reading.rs`, new: `trait DocumentReader: Send + Sync { fn read(&self, content: &VerifiedContent) -> DerivedRepresentations }`. A reader that fails returns nothing, so reading never holds back a submission. `work_execution.rs` calls it in `SubmitContent` after `read_submission_source`, and `ArchiveClient::submit` takes the result.
- `collection_core/src/archive_client.rs`: `HttpArchiveClient::submit` sends to `collected_documents`, and holds its submissions while the archive lacks it.
- `collection_command`: `PdfiumDocumentReader` over pdfium-render with a bundled PDFium. PDFium stays out of `collection_core`, so the applications never link it.
- `application_bindings`: a callback interface `DocumentReader` that `start_application_core` takes, and `prepare_document_submission` with `page_texts` and `thumbnail_path`.
- `scripted_archive`: both routes in `client_protocol.rs`, the submitted text and thumbnail kept with the document, and `--legacy-reception`, which answers the plain 403.

**Swift.**

- `native_client/document_reading/`, new, the module `DocumentReading` that both applications build, over PDFKit, Vision, and ImageIO: `PageTextReader.read(file:kind:) -> [String]`, `PageTextReader.recognize(pages: [CGImage])` for a scan whose pages are in memory, and `FirstPagePicture`, which takes `SubmissionPicture` and `PictureFile` from `submission_queue/`.
- iPhone: `SubmissionQueue` writes `page_texts.json` beside `thumbnail.jpg` when it enqueues. `SubmissionPreparation.prepare` passes both. `SubmissionTransfer` sets the method and headers of the request. `ConnectedArchive` gains the reception the archive offers.
- Mac: `ApplicationGateway` passes a `nonisolated` conformance of `DocumentReader` to the core, because the collector calls it from its own threads.

**Web.**

- `src/interface/document_reading.ts`, new: the page texts through PDF.js, the thumbnail on a canvas, the digest through `crypto.subtle`, and the body as `new Blob([text, thumbnail, file])`, which the browser streams from disk.
- `upload_tray.tsx` sends one PUT per file, at most three at once. `POST /api/documents` loses its last caller and goes in the same commit. Its GET stays.
- `scripts/evaluate_extraction.ts` and `evaluate_search.ts` send through the same module, so they score what the web application sends.

## Tradeoffs accepted

- We accept a body format of our own in exchange for a request the Worker never parses. The format is two counts, and `curl -T` sends the simplest case.
- We accept that the archive cannot check that a text belongs to its original. A token that may add a document can add a document with a wrong text. It cannot change the text of a document the archive holds, except a failed one under unit A1.
- We accept plain text per page for PDFs with a text layer. `toMarkdown` keeps tables as Markdown, and `TextParagraph` shows them as table rows. A client's text has no tables. Decision 6.
- We accept three extractors, PDFKit, PDF.js, and pdfium-render, in exchange for no extractor in the Worker. One fixture of expected values, `test_fixtures/documents/expected_extraction.json`, checks all three.
- We accept two copies of a submitted text in R2, in exchange for a `content.md` that is still written once.
- We accept the old routes and the clients' second way of sending until the last unit removes them. They are compatibility code with a named end.

## Alternatives considered

- **Multipart with the original last.** A standard format, and the iPhone writes multipart today. It lost because the Worker must parse headers and boundaries in JavaScript and trust the order of parts for the stream, so it hides nothing more than two counts do.
- **Text and thumbnail in their own requests before the original.** Small requests and no body format. It lost because a share extension cannot order three background uploads, and because representations without an original need their own storage, sweep, and race rules.
- **Optional headers on the existing `PUT /api/v1/contents/{sha256}`.** No new route. It lost because an old archive ignores the headers, hashes the prefix with the original, and answers 422 for ever, where a new route answers `RouteUnknown` once.
- **One Rust crate over objc2 for PDFKit and Vision on every Apple target.** One implementation behind `prepare_submission`. It lost because Vision through objc2 on the iPhone is untried, while the Swift calls are measured, and the iPhone holds a scan's pages as images in Swift already.
- **A text layer written into the PDF on the phone.** The iPhone note names it. It changes the bytes, and so the content, and the archive would still need PDFium to read it.

## Risks

1. An answer before the body is read may not reach a client that is still sending. It broke a Node client at 20 MB locally. The 200 for a held content and the 409 are such answers. On staging `curl` got the 200 for a held 20 MB content twice (measured, 2026-11-26). The iPhone's background session is not measured yet; unit C2 sends a held content from it. If its answer is lost, the reception reads the body to its end before it answers.
2. Settled: a `Request` built inside a workerd test gives a byte stream that `readAtLeast` and the `FixedLengthStream` read as one over HTTP does. Such a `Request` carries no `Content-Length`, so the tests set it.
3. Vision in the share extension, which the system ends above about 120 MB, is not measured on a 25-page scan. If it does not fit, the extension reads text layers only and leaves a submission that needs recognition unclaimed, so the application reads and sends it.
4. Bundling PDFium into `schublade-collector` on macOS is inferred from its Linux build. If it is awkward, the program on macOS uses PDFKit through objc2-pdf-kit.

## Decisions for the owner

The owner decided on 2026-11-26:

1. **What reads a scan or a photograph that arrives without text, once Moondream is gone?** Decided: Moondream stays for picture originals. R1 removes PDFium and the recognition of PDF pages, and R2 does not remove Moondream for pictures.
2. **Should a new build send the old way to an old archive, or say "Update your archive" and wait?** Decided: it says "Update your archive" and holds its uploads. A new client has no fallback, so each client's multipart writer goes in the unit that moves that client over.
3. **When may R1 run?** Open. The log line shows how many scans without text still arrive.
4. **Does `POST /api/documents/ingest` stay for scripts and Shortcuts for good?** Decided: no. It goes with the old clients in unit L1, and scripts send the PUT with the digest.
5. **Draw the thumbnails of old PDFs once before PDFium leaves, or let those nobody ever listed show a file icon?** Undecided. Unit B1 stays optional.
6. **Is plain text enough for PDFs with a text layer?** Decided: yes. No `toMarkdown` for every PDF.
7. **480 pixels for the thumbnail?** Decided: yes.

## Units

Each unit ends in its check and one commit on `main`. The server comes first and old clients keep working through every unit before R1.

| Unit | What | Tests under the lean rules | Check |
| --- | --- | --- | --- |
| S1 | The reception: `document_reception.ts`, the route entry, the member's path, `archiveContent` over a stream, the old `contents` route on the same function, the log line | Node: one table test of `parseReceptionHeaders`. workerd: a new content answers 202 and R2 holds three objects of literal sizes, the same request again answers 200 and writes nothing, a wrong digest answers 422 and stores nothing. The existing 409 and 503 tests run over both collector paths. One line per path in the route listing test | `pnpm check`. On staging: 20 MB twice with the ingest token, the CPU time of both routes, and the mismatch message of deployed R2 |
| S2 | The Workflow reads the submitted text, and classify reads `content.md` | workerd: a document with a submitted text is archived while `toMarkdown` and Moondream throw when called, and `content.md` equals the literal text. A submitted text of 10 letters takes today's chain | `pnpm check`. `pnpm dev`: a scanned fixture sent by `curl` with a text is archived without a Moondream entry in the gateway log |
| S3 | `readThumbnail` in its new order | workerd: a stored `thumbnail.jpg` is served as `image/jpeg`. The existing tests cover the PNG and the mark | `pnpm check` |
| C1 | The wire in Rust: `prepare_submission`, `compose_document_text`, the answers, `read_document_reception`, `put_document`, both routes and `--legacy-reception` in the scripted archive, and `test_fixtures/client_protocol/submitted_document_text.md`, which the Rust writer, the Worker's test, and the web's writer share | The body equals the fixture and the counts. Each answer reads as what the application does next. A submission to a legacy archive is held and reported as "Update your archive" | The cargo checks on Linux and the Mac |
| C2 | `DocumentReading` and the iPhone application with its share extension | Swift Testing: the text of one digital fixture and of one scanned fixture holds literal values of `expected_extraction.json`. End to end: the scripted archive holds the text of a scan the application sent | The iPhone's `check_application.sh`. On the owner's iPhone: a scan and a share of a 25-page PDF archive without a Moondream entry |
| C3 | `DocumentReader` in `collection_core`, the callback in the bindings, the Mac's conformance | One corpus scenario: the scripted archive holds the text a fixed reader returned. One coordinator test: a legacy archive holds the submissions | The cargo checks, the Mac's `check_application.sh` |
| C4 | `PdfiumDocumentReader` in `collection_command` | One test: the text of a digital fixture holds its literal values | The cargo checks on Linux and the Mac |
| C5 | The web application reads and sends, `POST /api/documents` goes, the evaluation scripts send text | Node: the page texts of one fixture through PDF.js hold its literal values, and the body equals the shared fixture | `pnpm check`. `pnpm dev` with a PDF and a photograph in a browser. `pnpm evaluate:extraction`, billed, with the owner's go |
| M1 | A printed email takes its text and its picture from Browser Run | workerd: with recorded answers of the three quick actions, a stored email is archived with the scraped text and a `thumbnail.jpg` | `pnpm check`. The local email endpoint with a mail fixture. The scraped text against PDFium's on the mail fixtures |
| A1 | A failed document takes a submitted text and is retried | workerd: one test | `pnpm check` |
| C6 | Optional, decision 1: an application sends the text of a failed document of its copy whose original it holds | One scenario against the scripted archive | The cargo checks |
| B1 | Optional, decision 5: the scheduled drawing of missing thumbnails | workerd: one run draws one and moves its position | `pnpm check`, then the log line "0 remaining" on the deployment |
| R1 | PDFium leaves: `page_rasterizer.ts`, the package, the 90% rule, the recognition of PDF pages | The tests of the removed code go. One workerd test of the fallback chain: no text and a short conversion fail with `unreadable_page` | `pnpm check`. The Worker's bundle size before and after |
| R2 | Not needed: decision 1 keeps Moondream for pictures | None | None |
| L1 | Later: `POST /api/documents/ingest` with its multipart (decision 4), and `contents` | The tests of the removed code go | `pnpm check` |

`AGENTS.md` and `notes/client_protocol.md` change with the unit that changes what they describe. `README.md` needs its upload example and its description of ingestion revised after C5 and R1, which the owner writes.

## What the server units changed in this design

- `parseReceptionHeaders` lives in `src/ingestion/reception_headers.ts`, because `document_reception.ts` imports the Workflow and PDFium and cannot run in the Node project.
- The route table has one entry per path, not one pattern for both, because each refusing route now names its refusal of a restricted token in `restrictedScopeRefusals`: `submitted_documents` says "Adding documents needs an unrestricted token", the collector's routes keep "A collector needs an unrestricted token".
- A 422 cannot name the digest it received, because the Worker never hashes the original. Its detail is "The original does not have the SHA-256 in the path".
- `contents` answers 411 to a body without `Content-Length`. The collector of build 1.0 sends one, because ureq sets it for a byte slice.
- The generated runtime types lack `readAtLeast`, so `src/ambient_declarations.d.ts` declares it.
- The 415 for an unaccepted original now comes before the 422 on `contents` as well.

## What unit C1 changed in this design

- `DerivedRepresentations.thumbnail` holds the JPEG's bytes, not a path, so the iPhone's body writer and a collector's `send_document` take one type. The bindings of unit C2 read `thumbnail.jpg` into it.
- `prepare_submission` takes no route, because only a person's submission is written to a file, and `PreparedSubmission` names no method, because it is always PUT. A collector sends from memory with `send_document(exchange, route, digest, derived, original)`, over `ArchiveExchange::put_document`.
- `read_submission_answer` takes the answer's `Content-Type`, because `RouteUnknown` is a 403 without `application/problem+json`, as every other route reads it.
- A text above 2,000,000 bytes, a thumbnail above 200,000 bytes, and a thumbnail that does not start with `FF D8 FF` are left out of the body rather than refused, so the archive reads the original itself and the document is never rejected for a derived representation.
- The multipart writer stays as `prepare_ingest_submission` and `read_ingest_submission_answer` in `ingest_submission.rs` until unit C2 moves the iPhone, and the bindings still call it.
- The scripted archive reads a person's upload to the reception at `--ingest-pace` too, so a screen examination of unit C2 shows its progress.

## What unit C3 changed in this design

The Rust part is built; the Mac application's PDFKit and Vision conformance is not, because the Mac could not be reached.

- `start_application_core` takes no new parameter. `ApplicationConfiguration` gains `document_reader: Option<DocumentReader>`, which UniFFI gives a default of `nil` in Swift, so the Mac and iPhone applications build unchanged and the Mac's collector sends the original alone until its conformance is passed there.
- The callback is `read(original: Data, mediaType: DocumentMediaType) -> DocumentReading`. It receives the verified bytes and not a path, so the text always belongs to the bytes the PUT sends, even when the file changes on disk meanwhile.
- The collector does not ask `read_document_reception` at connecting and once a day. Each submission asks before it reads its source, and `HttpArchiveClient` stops asking once the archive offers the reception, so an archive costs one GET per client. An archive without it holds every submission for an hour in memory, and the next submission after the hour asks again. A PUT that meets the plain 403 counts the same.
- "Update your archive" is `AttentionItem::ArchiveOutdated` of the collector, not the shared `ConnectionCondition::ArchiveOutdated`. That condition replaces the Mac's library with "Update your archive to use the library", but an archive without the reception still serves the library. Lookups and status reads go on, so a survey completes while uploads wait.
- A GET that meets a condition before the PUT counts no failure against the content (`SubmissionCondition::ReceptionUnknown`).
- `ArchiveExchange::put_octets` is gone with its caller. The scripted archive answers `contents` still, as the Worker does for collector build 1.0.

## What unit C5 changed in this design

Unit C5 is built: the web application and the evaluation scripts send to the reception, and `POST /api/documents` is gone.

- The browser sends no text when no page holds a readable text layer, so a scanned PDF arrives without one and the archive reads it. The Rust writer sends the headings alone for such a document. Both reach today's chain, because the Workflow needs 40 letters or digits.
- `Schublade-Page-Count` goes only with page texts, as in Rust, so a picture from the browser carries no page count and the Workflow records 1.
- The page texts follow `isReadableTextLayer` of `document_text.ts`, and the limits of a text and a thumbnail come from `reception_headers.ts`, so the browser and the reception share one rule. The sentence for an unaccepted kind moved to `source_file.ts`, and the browser answers it without sending the file.
- PDF.js reads the text and draws the page in its own workers, so no worker of our own was needed. The longest main-thread task while a digital PDF and a photograph were read and sent was 125 ms, in the development build (measured, 2026-11-26).
- The browser reads and sends at most three files of a tab at once, each a PUT of its own.
- `document_reading.ts` runs in Node for the evaluation scripts, so its imports name their `.ts` files. Node has no canvas, so the scripts send no thumbnail and the archive draws one.
- A POST to `/api/documents` now answers the archive's page, as TanStack Start answers a method a route lacks, and archives nothing.

## What unit M1 changed in this design

- The text and the picture are two steps after "render email", "read email text" and "draw email thumbnail", not two more actions inside it. Workers Free allows one quick action every 10 seconds (documented), so three actions in one step would be refused together on every retry, while a step of its own is retried alone after 10 seconds (inferred, not run on Free). Each step reads the stored message again, because a step's result keeps no page.
- The text goes to `submitted_text.md` and the picture to `thumbnail.jpg`, the keys of a client's text and thumbnail, so the extract text step and `readThumbnail` take them without a change, and a retried email reads its text again. The text is the scrape's `text`, Chromium's `innerText` of `body`, with no page headings, because the page count is unknown.
- The text passes the same 40 letters or digits rule as a client's. The printed header alone almost always passes it, so an email of nothing but pictures is archived with its header. One whose header and body hold fewer than 40 still reads the printed PDF through today's chain until R1.
- `selectPrintedMailTextSources` and `printedHeaderText` went in M1 and not in R1, because the header is part of the scraped page.
- The picture is a `screenshot` of an A4 viewport, 794 by 1123 CSS pixels, clipped at the scale 480/1123. Browser Run honoured the clip's scale: each answer was a 339 by 480 JPEG of 3.6 to 18 KB (measured, 2026-11-26).
- Measured on 2026-11-26 through `pnpm dev`, because the shell's token is refused by Browser Run's REST API: three messages, the test's receipt, a forwarded HTML receipt with layout tables, a style sheet, and a hidden preheader, and a plain-text utility statement, each printed, scraped, and pictured once, nine quick actions in all. PDFium's text layer of each recorded PDF and the scraped text held the same letters and digits (64 of 64, 761 of 761, 460 of 460) and the same words, and neither held the hidden preheader. The scrape reported 64 to 84 ms of browser time; the PDF and the screenshot reported none in `X-Browser-Ms-Used`. The browser time is far below the 10 hours a month that Workers Paid includes, so the measurement cost nothing beyond the plan. The three messages also passed classification and indexing, which billed three classifications and three AI Search uploads on the development instance.
- The receipt's answers are recorded in `test_fixtures/inference_recordings/receipt_email.json` and `receipt_email.pdf`, which the ingestion tests answer with.

## What unit C4 changed in this design

- PDFium is not linked into `schublade-collector`. pdfium-render binds it when the program starts, from the file `SCHUBLADE_PDFIUM_LIBRARY` names, then beside the executable, then the system's library search path, because bblanchon/pdfium-binaries publishes shared libraries only. `native_client/scripts/fetch_pdfium_library.sh` installs build `chromium/8125`, the one pdfium-render 0.9.6 binds to, after checking the SHA-256 that GitHub records for each archive. Without the library the program sends each original alone and warns once on `decide` and `collect`.
- A PDF with no readable page goes without text, as from the browser, so the reception records no page count for it. `is_readable_text_layer` in `archive_access` applies the rule of `isReadableTextLayer` to each page, and PDFium's `\r\n` line breaks become `\n`.
- The thumbnail is the first page drawn at 480 pixels on its longer side and encoded as a JPEG of quality 80. On the test documents an A4 page gave 339 by 480 pixels and 21 to 28 KB (measured, 2026-11-26). A picture original gets neither text nor thumbnail, and the archive serves the picture itself.
- Measured on 2026-11-26 against `scripted-archive-server`: the program sent `telecommunication_invoice_digital.pdf` and `dental_invoice_scanned.pdf` to `collected_documents`, and the archive held the text of the first, no text for the second, and a JPEG thumbnail of each. Risk 4, PDFium on macOS, is still unmeasured, because the Mac could not be reached.

## Next implementation step

Unit C2: `DocumentReading` and the iPhone application with its share extension. The bindings publish `prepare_submission` with `page_texts` and `thumbnail_path`, `read_submission_answer` with `RouteUnknown`, and `read_document_reception`, and the iPhone's multipart writer goes.
