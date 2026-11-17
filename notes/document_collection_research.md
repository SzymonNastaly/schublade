# Document collection research

Research notes of 2026-11-17 for making Schublade an archive that fills itself from a Mac, an iPhone, and later cloud services. The build order below records what is built. Each external claim is marked **verified** (a research subagent read the source in this session) or **from memory** (model knowledge, not checked).

## Decisions the owner made

| Question                                 | Answer                                                               |
| ---------------------------------------- | -------------------------------------------------------------------- |
| What the desktop collector picks up      | Folders the user chooses, with a one-time backfill of their contents |
| A second copy of a document arrives      | Keep the best one                                                    |
| iPhone                                   | Native app                                                           |
| Who installs the collector               | Other self-hosters, on macOS, Windows, and Linux                     |

## Where ingestion stands today

- `POST /api/documents/ingest` takes a bearer token of level `ingest` and a multipart body (`src/ingestion/token_ingestion.ts`). The limits are 20 files, 25 MB per file, and 50 MB per request (`src/ingestion/document_upload.ts`).
- A browser or token upload gets a random document identifier, so the same file sent twice becomes two documents.
- Inbound mail already derives the document identifier from the Message-ID (`deriveDocumentIdentifier` in `src/ingestion/inbound_mail.ts`), and `acceptDocumentUpload` already inserts with `onConflictDoNothing`. The same pattern with a content hash gives exact deduplication.
- Only the exact path `/api/documents/ingest` and the OAuth paths skip Access. `request_dispatch.workerd.test.ts` fails on a prefix comparison. A versioned API under a prefix therefore needs a deliberate new rule, a new Access bypass application, and a dispatcher branch that authenticates bearer tokens for the whole prefix and never falls through to a member session.
- Accepted kinds are PDF, JPEG, PNG, and WebP. An iPhone photograph is HEIC unless the app converts it.

## Proposed model

Three things have separate identities.

- **Content.** One exact byte sequence, named by its SHA-256. A content record outlives its document, so a file the user deleted from the archive is still known and no collector sends it again.
- **Document.** The letter or invoice. It shows one preferred content, and it can hold superseded contents.
- **Sighting.** A device saw a content at a place and time (device, path or source locator, origin URL when the system records one). Sightings are provenance. They never delete anything, which is why removing a file from Downloads leaves the archive alone.

## Proposed protocol

Four requests cover every collector.

| Request                                 | Purpose                                                                                                                                             |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /api/v1/devices` with a pairing code | Exchange a single-use code from Settings for a device token of level `ingest`                                                                       |
| `POST /api/v1/content-inquiries`        | Send up to 1000 SHA-256 values with their sightings, receive the ones the archive lacks                                                             |
| `PUT /api/v1/contents/{sha256}`         | Stream one file with its length. R2 verifies the hash. A repeat returns the existing document. The answer is 202 with the document location        |
| `GET /api/v1/documents/{id}`            | Read the status and the duplicate decision                                                                                                          |

Sources for the shape:

- Immich asks the server about checksums before uploading, the OCI registry answers `HEAD` by digest, Git LFS has a batch request, and restic names a blob by its hash. **From memory.** The Immich pages did not load.
- R2 `put()` accepts a `sha256` option that checks integrity, `onlyIf` conditions, and a stream of known length, so the Worker need not buffer. **Verified**, <https://developers.cloudflare.com/r2/api/workers/workers-api-reference/>.
- Worker request bodies allow 100 MB on Free and Pro. Memory is 128 MB per isolate. **Verified**, <https://developers.cloudflare.com/workers/platform/limits/>.
- A presigned R2 URL needs S3 credentials in the Worker, and the page documents no size or checksum enforcement. **Verified**, <https://developers.cloudflare.com/r2/api/s3/presigned-urls/>. Streaming through the Worker is simpler.
- Errors as RFC 9457 problem details. **Verified**, <https://www.rfc-editor.org/rfc/rfc9457.html>.
- Resumable upload is still an IETF draft (revision 15 in November 2026). **Verified**, <https://httpwg.org/http-extensions/draft-ietf-httpbis-resumable-upload.html>. It is not worth building for 25 MB files, with one exception under iPhone below.

## Desktop collector

The loop is discover, settle, hash, inquire, upload, record.

- **Discover.** A file event stream plus a periodic full walk of the chosen folders. Events are lost while the collector is stopped or a volume is unmounted. **From memory.** FSEvents can replay from a stored event identifier. **Verified only through a summary** of <https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate>.
- **Settle.** Ignore `.crdownload`, `.download`, and `.part`, then wait until size and modification time stop changing. **From memory.**
- **Dataless files.** An evicted iCloud file carries `SF_DATALESS` in `st_flags`. A plain read forces a download that can time out. **Verified through search summaries**, <https://eclecticlight.co/2023/10/25/macos-sonoma-has-changed-icloud-drive-radically/>. Check the flag before hashing.
- **Local state.** A SQLite table of path, size, modification time, inode, SHA-256, and outcome. It is a cache. When it is lost the collector hashes again and the inquiry answers, so nothing is sent twice.
- **macOS permissions.** Downloads, Desktop, and Documents are protected folders. A bare binary under launchd has no application to attribute consent to. An agent registered through `SMAppService` makes its application the responsible process. **Verified**, <https://developer.apple.com/forums/thread/756510>. The reliable macOS form is a thin signed application around the core. This needs a check on a real Mac before any build.
- **Provenance.** The `kMDItemWhereFroms` attribute holds the URL a file was downloaded from. **From memory.** It can inform classification the way `MailContext` does.

### Language

| Language   | For                                                                                                                                    | Against                                                                                           |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Rust       | `notify` uses FSEvents, ReadDirectoryChangesW, and inotify (**verified**, <https://github.com/notify-rs/notify>). One static binary per system. Reusable on iOS through UniFFI (**from memory**) | A second language in the project. macOS still wants a signed application wrapper                 |
| Go         | Easy cross-compilation. Syncthing, restic, and rclone use it (**from memory**)                                                          | `fsnotify` uses kqueue on macOS and has no FSEvents (**verified**, <https://github.com/fsnotify/fsnotify>) |
| TypeScript | Same language and zod schemas as the Worker. `@parcel/watcher` has FSEvents (**from memory**)                                           | Single-file executables are large (**from memory**). A runtime to keep patched                    |
| Swift      | Native FSEvents, `SMAppService`, signing, and shared code with the iPhone app                                                           | Weak on Windows and Linux, which the owner wants                                                  |
| Zig        | Small binaries                                                                                                                         | Young libraries for watching, SQLite, and HTTP (**from memory**)                                  |

Recommendation: Rust for the core. The protocol is four requests, so the portable asset is the protocol, and a client in any language stays small.

## iPhone

- No third-party app can see a new file in the Files app while it is not running. `NSFilePresenter` and `NSMetadataQuery` deliver only to a live process. **From memory, high confidence.** No iOS 26 or 27 change was found.
- Background tasks run when the system chooses and stop after a force quit. **From memory.**
- A Share extension can take a PDF from any share sheet, copy it to an app group container, and hand it to a background `URLSession`. Background uploads must be file-based and continue after the system terminates the app. A user force quit cancels them. **Verified**, <https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:).md>.
- Shortcuts on iPhone have no folder trigger. Those are Mac-only. **Verified in part**, <https://support.apple.com/125148>.
- iOS 26.1 added a PhotoKit background upload extension, replaced in iOS 27 by `PHBackgroundResourceUploadJobExtension`. The system uploads photo library resources while the app is not running. It covers photographs only, and the server must speak the IETF resumable upload draft, including an `OPTIONS` answer with `Upload-Limit` and a `104` response. **Verified**, <https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background.md>. Whether a Worker can send a `104` response is unknown and needs a prototype.
- Mail attachments, WhatsApp files, and banking app storage are unreachable until the user shares them. **From memory.**
- Distribution needs a paid developer account, and TestFlight builds expire after 90 days. **From memory.**

Verdict: unattended for photographs, one tap for files, impossible for watching Files.

## Cloud services

- **Locally synced folder.** The desktop collector watches the Dropbox, Google Drive, OneDrive, or iCloud folder. No OAuth. The dataless rule above applies. **From memory.**
- **Connector in the Worker.** Google Drive `drive.readonly` is a restricted scope that needs verification, and a watch channel lasts at most a week. **Verified**, <https://developers.google.com/workspace/drive/api/guides/api-specific-auth> and <https://developers.google.com/workspace/drive/api/guides/push>. Dropbox cursors and OneDrive delta queries are easier. **From memory.** iCloud Drive has no server API. **From memory.**
- A connector is one more collector that speaks the same protocol, so it can wait.

## Duplicates

Tiers, cheapest first.

1. **Same bytes.** SHA-256, answered before any upload.
2. **Same text.** A hash of the normalized page text after extraction. It catches a portal download whose PDF metadata changed. **From memory.**
3. **Same document, other rendition.** Find candidates with a character n-gram fingerprint per page (MinHash or SimHash) or through the existing search index. A few thousand rows compare by brute force in milliseconds. **From memory.** Then verify with the tokens that carry digits (dates, amounts, IBANs, invoice numbers) and the extracted fields.

Facts behind the design:

- Text similarity alone rates two monthly invoices from one sender as near-identical. The digit-bearing tokens separate them. **From memory.**
- Perceptual image hashes fail on a photograph of a printed page. **From memory.** PDQ suggests a distance of 31 on 256 bits for re-renders. **Verified**, <https://github.com/facebook/ThreatExchange/blob/main/pdq/README.md>.
- Word shingles are brittle under recognition errors, and character n-grams degrade more slowly. **From memory, no benchmark found.**
- paperless-ngx compares checksums only, and its maintainer declined consume-time near-duplicate checks. **Verified**, <https://github.com/paperless-ngx/paperless-ngx/discussions/2716>. Immich uses an embedding distance near 0.02 and asks a person. **Verified**, commit linked in the subagent report. No system found merges near-duplicates on its own.
- Containment, not Jaccard similarity, handles a missing blank page or a document inside a combined scan. **Verified**, <https://www.cs.princeton.edu/courses/archive/spring13/cos598C/broder97resemblance.pdf>.

"Keep the best one" as proposed: the document shows the best rendition (a PDF with a text layer, then a scan, then a photograph, and the sharper of two of one kind). A superseded original stays in R2 under the document and can be restored. The archive never deletes on a near-duplicate judgment. A recognition error in a digit makes two copies look different, which leaves a visible duplicate. The opposite error would hide a document, so the uncertain band keeps both and marks them.

The thresholds are unknown until measured. `scripts/test_document_generation/` already simulates scans and photographs, so an evaluation in the style of `pnpm evaluate:extraction` can generate pairs and monthly series and score the decision.

## Follow-up decisions

- **One entry per document.** The owner's "keep the best one" means the archive lists a document once, however many devices and folders hold it. Nothing on a client is ever deleted. Identical files become one content with several sightings. A different file of the same document joins the existing entry, and the archive keeps that file in storage behind the entry.
- **Set aside.** A file that is no household document is set aside, and its SHA-256 stays known so no collector sends it again.
- **Order.** The API with exact deduplication first, then the Mac collector, then near-duplicates, then the iPhone app.
- **Work on the client.** The client computes hints and the archive decides, because browser uploads and mail never pass a collector.
  - SHA-256 of the bytes, always.
  - For a PDF with a text layer, the normalized text hash and a text fingerprint, computed with PDFium. The Worker already extracts text with PDFium (`@embedpdf/pdfium`), so both sides read the same text. **Inferred**, not tested across PDFium builds.
  - For a scan or photograph, recognition on the device is possible on Apple systems through the Vision framework. **From memory.** Windows and Linux need another engine, so their text differs and only a fuzzy fingerprint can compare it.
  - Every hint carries the version of its algorithm.
  - Docling is a Python toolkit with layout models. It suits a server process and does not fit a single static binary or an iPhone app. **From memory.**
  - An embedding from a small local model finds similar documents but cannot separate two months of one invoice, and both sides must run the same model. **From memory.**
- **A model as the judge.** The uncertain band of tier 3 goes to a language model with both texts and both sets of extracted fields. The archive already calls one through `CLASSIFICATION_MODEL` in `src/inference/document_classifier.ts`. Workers AI also has `@cf/baai/bge-reranker-base`, which scores how relevant a passage is to a query. **Verified**, <https://developers.cloudflare.com/workers-ai/models/bge-reranker-base/>. Relevance is not identity, so the reranker can rank candidates but should not decide.

## Clef decision models

Read on 2026-11-17 from <https://developers.cloudflare.com/changelog/post/2026-10-01-clef-workers-ai/>, <https://developers.cloudflare.com/workers-ai/models/clef/>, <https://developers.cloudflare.com/changelog/post/2026-10-09-clef-omni-workers-ai/>, and <https://blog.cloudflare.com/clef-decision-models/>. All **verified** unless marked.

- A decision model writes no text. A request holds a `state` (text or JSON, plus up to four PNG, JPEG, or WebP images) and 1 to 64 typed questions. `noul` returns the probability of yes, `choice` returns a probability per option, and `score` returns a probability per level of an ordered rubric.
- Output tokens are free. The text state is truncated silently when the request exceeds the context window.

| Model                       | Backbone             | Context | Price per million input tokens | Median latency |
| --------------------------- | -------------------- | ------- | ------------------------------ | -------------- |
| `@cf/cloudflare/clef`       | 27B                  | 64K     | 0.24 USD                       | 209 ms         |
| `@cf/cloudflare/clef-flash` | 9B                   | 64K     | 0.038 USD                      | 39 ms          |
| `@cf/cloudflare/clef-omni`  | 30B, 3B active       | 64K     | 0.15 USD                       | about 20 ms for text |

- Clef-omni adds audio and video, which the archive does not hold.
- The weights are Apache 2.0 on Hugging Face. A 9B model is too large to ship inside a collector (**guess**).
- Whether Clef-flash takes images was not checked. How well any of them reads German letters is unknown.

Where a decision model fits in the archive, strongest first:

1. **Duplicate judge.** The state holds both texts, both sets of extracted fields, and the digit-bearing tokens that only one side has. A `choice` question offers same document, corrected version, same template and other period, and unrelated. The probability maps onto the bands: join, keep both and mark, distinct.
2. **Set aside.** A `noul` question on the first page asks whether the file is a household document. It runs before classification, so a manual costs no classification.
3. **Best rendition.** A `score` question rates the legibility of a page image, which ranks two scans.
4. **Plausible client transcription.** A `score` question rates whether text sent by a collector reads as a coherent transcription of the page image before the archive trusts it.
5. **Page orientation.** A `choice` question with four options on the page image, asked before recognition. Today a page that hits the token limit is read at all four rotations.
6. **Document boundaries in a stack scan.** A `noul` question per page asks whether a new document starts there.
7. **Closed-set fields of classification** (category, household member). Possible, but the generative model must still write title, summary, and fields, so this adds a call and is the weakest case.

The digit comparison is demoted. It no longer decides. Recognition misreads digits, date formats vary, and a scan can carry a stamp or lose a footer, so a strict comparison is brittle. The token differences become evidence in the state of the duplicate judge.

Every use needs recorded responses in the workerd tests and an evaluation on generated pairs before it is trusted.

## Recognition on the client

- The archive already prefers a readable text layer. `selectPageTextSources` in `src/ingestion/document_text.ts` sends a page to Moondream only when its text layer holds fewer than 40 letters or digits or too many replacement characters. A scanned PDF that arrives with a text layer therefore costs no recognition today, with no change to the archive. **Verified in the code.**
- Writing a text layer changes the bytes. The identity of a content must stay the SHA-256 of the original file, or the same scan from a phone and from a Mac no longer match.
- Two forms: the collector uploads a PDF with an added text layer, or it uploads the original with the page texts beside it. The second keeps the original untouched and also works for photographs, which cannot hold a text layer.
- The archive trusts a text layer as it is, so poor recognition on a client would be archived without the Moondream fallback. A plausibility check is needed (item 4 above).
- `kreuzberg` 4.10.4 is MIT licensed and lists the features `bundled-pdfium`, `ocr`, `paddle-ocr`, `auto-rotate`, `layout-detection`, and `quality`. **Verified** on crates.io. Its recognition quality on photographed letters is untested.
- PDFKit can save a PDF with recognized text on macOS 13 and iOS 16 or later. **From memory.**

## Verification plan

What exists: `scripts/generate_test_documents.ts` renders the 12 specifications of `scripts/test_document_generation/document_catalog.ts`, each with one capture method (digital, scanned, photographed), from seeded random sources. A run on 2026-11-17 wrote 13 files of 1.85 MiB in 34.6 seconds and left the working tree unchanged, so the generator is deterministic. **Measured.** `pnpm evaluate:extraction` uploads the fixtures to a dev server and scores the result against `expected_extraction.json`.

### Collection corpus

A second generator output, laid out as the folders of a computer (`Downloads/`, `Desktop/`, `Documents/Scans/`, a synced cloud folder), with a manifest that states for every file the document it belongs to and the outcome the archive must reach.

| Case                                                                          | Expected outcome                    |
| ----------------------------------------------------------------------------- | ----------------------------------- |
| The same file in three folders                                                | One entry, three sightings          |
| The same PDF written again with another creation date and identifier          | Joins the entry                     |
| A digital PDF and a flatbed scan of it                                        | Joins the entry, the PDF is shown   |
| A digital PDF and a photograph of it                                          | Joins the entry                     |
| Two scans of one page with different skew and noise                           | One entry                           |
| A scan without its blank back page, and one with its pages in another order   | Joins the entry                     |
| A scan turned by 90 or 180 degrees                                            | Joins the entry                     |
| Six monthly invoices of one sender                                            | Six entries                         |
| Two invoices whose amounts differ in one digit                                | Two entries                         |
| An invoice and its corrected version                                          | Two entries, marked as related      |
| Consecutive bank statements                                                   | Separate entries                    |
| A manual, a scientific paper, a book                                          | Set aside, hash remembered          |
| A file still downloading, an empty file, a text file named `.pdf`, an oversized file | Never uploaded, or refused once     |
| Two documents in one stack scan                                               | Decided later, recorded as a known gap |

### Layers

| Layer                         | What it proves                                                                                                    | Runs in                     | Billed |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------- | --------------------------- | ------ |
| Unit tests                    | Hashing, fingerprints, digit tokens, decision bands                                                               | `pnpm check`                | No     |
| workerd tests                 | The API: inquiry, upload under a hash, a repeated upload, a deleted document stays known, recorded Clef responses | `pnpm check`                | No     |
| Collector scenario tests      | Drop, rename, delete, restart, a crash during upload, a lost state database, each ending in the expected archive  | `cargo test` on three systems in CI | No     |
| `pnpm evaluate:duplicates`    | The whole corpus against a dev server, scored against the manifest                                                | A dev server with a login   | Yes    |
| Real captures                 | Printed synthetic documents, photographed and scanned with real devices                                           | The same evaluation         | Yes    |
| Report-only run               | The judge lists the joins it would make in the owner's archive and changes nothing                                | The deployment              | Yes    |

The evaluation counts two errors separately. A wrong join hides a document and must be zero. A missed duplicate leaves two entries and is tolerable.

Recognized text and Clef responses are cached on disk under the content hash, so a second evaluation run of unchanged files costs nothing, and the cache feeds the recorded responses of the workerd tests.

### Storage

- The generator and the manifest go into git. The generated corpus is reproducible, so storing it is optional. At about 3 seconds per document, 80 files take about 4 minutes to generate (**inferred** from the measured run).
- Real captures cannot be regenerated. They belong in Git LFS. `git-lfs` 3.4.1 is installed on the development server (**verified**). The CI checkout needs `lfs: true`.
- Cached transcriptions and recorded responses are small JSON files in plain git.

### Build order

1. Install the Rust toolchain on the development server. Done on 2026-11-17 with rustup 1.29.3: rustc 1.100.0 and cargo 1.100.0, minimal profile with clippy and rustfmt, under `~/.cargo` and `~/.rustup`. rustup added one line to `~/.profile` and `~/.bashrc`. A trial program with `notify` 8.2.2 reported `Create(File)` for a file written into a watched directory. The server is replaceable, so a new server needs this step again.
2. The collection corpus generator and its manifest. Built on 2026-11-17 on the branch `collection-corpus`, not yet on `main`. `pnpm generate:collection-corpus` writes 40 files of 21 documents in 16 cases (4.40 MiB, about 70 seconds) to `test_fixtures/collection_corpus/` and the manifest to `test_fixtures/expected_collection.json`. The oversized file is left to the collector tests, which create it at run time.
3. **Next task.** The API with exact deduplication.
4. The collector with the byte hash and the text-layer fingerprint.
5. The duplicate judge and the set-aside question on Clef, with `pnpm evaluate:duplicates`.
6. Recognition on the client, tried with `kreuzberg`.
7. The iPhone app.

### A graphical application, not a command line

The owner wants people without a terminal to use the collector. The collector is therefore a library with thin programs around it.

- **Core library crate.** Folder watching, settling, hashing, fingerprints, the local state, and the four requests. It prints nothing. It takes a configuration (archive address, device token, folders) and reports events (found, uploading, archived, joined, set aside, failed).
- **Desktop application.** A tray application that pairs with the archive through a code, lets the user pick folders, shows what happened, starts at login, and updates itself. Tauri 2.12.6 has a `tray-icon` feature, and `tauri-plugin-autostart` and `tauri-plugin-updater` exist (**verified** on crates.io). Its interface is a web view, so it can reuse React, Tailwind, and the theme of `src/styles.css`. A signed application bundle also gives macOS a stable identity for folder consent (**inferred**).
- **Command-line program.** A second thin program over the same library, for the scenario tests, for CI, and for a server without a screen.
- **iPhone.** A Swift application, because the share extension, background uploads, and the PhotoKit extension are native targets. It can link the core through UniFFI 0.32.2 (**verified** that the crate exists, not tried).
- Distribution to people without a terminal needs signed installers: an Apple Developer ID with notarization, and a code signing certificate on Windows (**from memory**).

### Decisions on the application

- **Location.** The collector lives in this repository, in `collector/`.
- **Systems.** macOS first. The owner has an Apple developer account for signing and notarization. Windows is not a focus now. Linux is covered by the tests, because the development server runs Linux.
- **Menu bar.** An optional menu bar item on macOS. The Tauri tray icon has `set_visible`, `set_icon_as_template` (macOS only), and `set_show_menu_on_left_click`, and `remove_tray_by_id` removes it (**verified** in the API reference on docs.rs). A left click can show a window (**verified** in <https://v2.tauri.app/learn/system-tray/>). Running without a Dock icon is possible through the macOS activation policy (**from memory**, not found in the pages read).
- **Interface data.** The core's SQLite database on the same machine is the source of truth, so every read is local. The window reads through Tauri commands and receives the core's events. TanStack Query caches the reads and the events update its cache. The web application already depends on `@tanstack/react-query` 5 (**verified** in `package.json`). TanStack DB is at 1.0.0-rc.1.5 of 2026-11-11, a release candidate (**verified** on npm). It suits data that syncs from a server, which the collector window does not have.

### Limits of this development server

It runs Linux without a Rust toolchain. It can build the corpus, the API, and their tests, and after installing Rust it can test the collector against inotify. FSEvents, the macOS consent prompts, and evicted iCloud files can only be verified on a Mac, by the owner or by a macOS runner in CI.

## Open questions

1. A PDF in Downloads that is no household document, such as a manual or a paper. Archive it, or set it aside with its hash remembered?
2. Is recoverable supersession acceptable as the meaning of "keep the best one"?
3. How a backfill of thousands of files is paced and what it costs in recognition and classification.
4. Whether a Worker can serve the resumable upload draft that the PhotoKit extension requires.
5. How a macOS agent written in Rust obtains consent for Downloads on macOS 26.
