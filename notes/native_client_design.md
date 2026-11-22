# Native client design

The design of Schublade as one native application for the Mac, and later the iPhone, agreed on 2026-11-22. A person browses, searches, and reads the archive in it without the browser, from a local copy of every record, and the collector that fills the archive from Mac folders is one part of it. It supersedes the design of the collector application agreed on 2026-11-21 (commit `5072749`), whose units 1 and 2 landed and stay. `notes/client_protocol.md` is the reference for the routes under `/api/v1` that this design reads. The base came from one of two parallel candidates. [Synthesis decision](#synthesis-decision) lists what the other contributed.

## Problem

The owner wants one native Schublade, pure AppKit over a Rust core behind generated bindings, with strong types and few tests. The agreed design was a collector with a window. Reading must now be designed as if it had been there from the first day, and the iPhone must be able to read with the same core and without the collector.

Five things make the shape non-obvious.

- **The archive cannot say what changed.** `documents.updated_at` holds whole seconds, so a write in the second a client read carries the same value. A category rename changes no document row (`renameTaxonomyRecord` with `nameIndexed: false`), and a deleted document leaves no row. 34 write statements in `src/` touch the tables a client copies, counted with `grep` on 2026-11-22, and `pnpm run provision` writes household members with `cf d1` from outside the Worker. A client that keeps a copy needs a total order of changes that no writer can forget to feed.
- **The only door is `/api/v1` with a bearer token.** Cloudflare Access bypasses that prefix alone, and changing Access needs the owner. The browser's change socket sits behind Access. Everything new is a bearer-token route under the prefix and grows there by addition, because `/api/v2` would need the owner too.
- **The collector core owns the connection.** Its state store holds the archive origin, its coordinator holds the machine that says whether the archive answers, and it reads the token from the Keychain. A second core that reads the archive needs the same address and token, and must cause neither a second Keychain prompt nor a second record of which archive this Mac belongs to.
- **A list of thousands of documents crosses a language boundary.** UniFFI copies every value. The bindings follow one pattern today, the long read by revision, which answers a whole status. A whole listing per change does not scale the same way.
- **The archive's search is billed per query** and reaches a new document minutes after its archival. A search field that feels native answers as a person types, also on a train.

## Usage (caller's view)

### A person

Jonas opens Schublade from the Dock. The window is where he left it, on All Documents, with yesterday's letters on top and the status line reading "Up to date · 14:02". Two documents that the archive is still reading sit above the month headings under "Arriving". He presses Command-F and types "versicherung". The list shows the rental contract whose details name a "Haftpflichtversicherung" first, then the letters whose text holds the word, each with the sentence around it. He presses Down twice, and the reader shows each PDF as he goes. In the inspector he clicks the copy control beside the IBAN, and drags the row into a Mail message. He closes the window. The drawer in the menu bar stays.

In the evening he scans six letters into Paperwork. The drawer's glyph shows a sheet sinking in. He clicks it and sees six titles under Recently Added, the first still arriving. On the train, without a network, he searches for the tax assessment and reads it, because he opened it last week. A document he never opened says "The Original Is Not on This Mac", and its details and text are there.

The first time, the whole window is a form with the archive's address and a token from the archive's Settings. Connect checks both against the archive before anything is stored. A token that may only add documents connects the collector only, and the library says that the token cannot read.

### The Swift application, of the bindings

`ApplicationController` starts the core through the gateway and follows the library and the collector with two loops on the main actor. Each loop writes only its half of the situation.

```swift
private func followCore() async {
	do {
		try await gateway.start(configuration: environment.applicationConfiguration)
	} catch {
		change(to: .failedToStart(error))                        // an ApplicationStartFailure
		return
	}
	async let library: Void = followLibrary()
	async let collector: Void = followCollector()
	_ = await (library, collector)
	change(to: .stopped)
}

private func followLibrary() async {
	var revision: UInt64?
	while let status = try? await gateway.libraryStatusAfter(revision) {
		revision = status.revision
		situation.library = status                               // renders the window and the menu bar item
		if status.contentRevision != shownContentRevision {
			shownContentRevision = status.contentRevision
			window.contentRevisionChanged(to: shownContentRevision)
		}
	}
}
```

`followCollector()` is the same loop over `gateway.collectorStatusAfter(_:)`, and it returns at once on an iPhone or in any start without a collector.

The document list asks for a listing and receives the difference from the one it shows:

```swift
private func refresh() {
	let number = nextRequestNumber()
	Task {
		guard let answer = try? await queries.listDocuments(request, preceding: model.listing),
		      number == newestRequestNumber else { return }        // an older answer is dropped
		switch model.adopt(answer) {
		case .reload:
			tableView.reloadData()
		case let .difference(removed, inserted, revised):
			tableView.beginUpdates()
			tableView.removeRows(at: removed, withAnimation: .effectFade)
			tableView.insertRows(at: inserted, withAnimation: .effectFade)
			tableView.endUpdates()
			tableView.reloadData(forRowIndexes: revised, columnIndexes: [0])
		}
	}
}

func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
	rowView(for: model.row(at: row))                               // from memory, no await
}
```

The reader asks for a file and words the refusal. It never knows whether the file was cached:

```swift
do {
	let file = try await queries.original(document)
	pdfView.document = await openPortableDocument(at: file)
} catch {
	showPlaceholder(representationRefusalSentence(error))          // a RepresentationRefusal
}
```

A screen of the collector sends a command and words the refusal, as in the agreed design:

```swift
@objc private func uploadBacklog() {
	decision = Task {
		do {
			try await commands.decideBacklog(wording.folder.identifier)
			// The next status no longer has this folder awaiting a decision, so the page changes itself.
		} catch {
			refusalLabel.stringValue = decisionRefusalSentence(error, context: context)   // a DecisionRefusal
		}
	}
}
```

### The replica, of the routes

One step of the replica's coordinator thread. The reader answers in domain terms, the store applies, and the machine decides what comes next:

```rust
let requested_after = store.cursor()?;
let input = match reader.read_changes(requested_after.as_ref()) {
	Ok(PageAnswer::Page(page)) => match store.apply_page(requested_after.as_ref(), &page, clock())? {
		PageApplication::Applied { unsettled_documents, .. } => SynchronizationInput::PageApplied {
			complete: page.complete,
			entries: page.entry_count(),
			remaining_entries: page.remaining_entries,
			unsettled_documents,
		},
		PageApplication::CursorMoved => return Ok(()),           // another page got there first: nothing to do
	},
	Ok(PageAnswer::JournalReplaced) => {
		store.discard()?;
		SynchronizationInput::JournalReplaced
	}
	Err(condition) => SynchronizationInput::RequestFailed(condition),
};
let (next, effects) = advance_synchronization(state, input, attendance, clock(), &timing);
```

### A test, of the synchronization

The one test the design cannot do without. The scripted archive keeps records and a journal by the Worker's rules. A seeded script changes it and synchronizes a copy at arbitrary points, with small pages, repeated pages, and restarts:

```rust
#[test]
fn a_copy_equals_the_archive_after_any_interleaving() {
	for seed in 0..300 {
		let archive = ScriptedArchive::with_page_entries(3);
		let mut copy = ReplicaUnderTest::in_temporary_directory();
		for step in Script::seeded(seed).take(400) {
			match step {
				Step::Change(change) => archive.apply(change),     // create, revise, retag, delete, rename, merge, restrict
				Step::RequestPages(count) => copy.request_pages(&archive, count),
				Step::ApplyLastPageAgain => copy.apply_last_page_again(),
				Step::RestartBeforeCommit => copy.restart_discarding_the_open_transaction(),
				Step::ReplaceJournal => archive.replace_journal(),
			}
		}
		copy.request_pages_until_complete(&archive);
		assert_eq!(copy.records(), archive.records_admitted_to(copy.scope()), "seed {seed}");
		assert!(copy.every_reference_resolves(), "seed {seed}");
	}
}
```

## Shape

### The product and its first version

A person opens Schublade to find a document and read it, and to see that new paper arrived. The first version does those three things without a network round trip for anything it has seen before, and it collects from folders as the collector does today.

| A person can                                                | How                                                                                                                       |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Browse every document, by person, category, tag, or sender  | The sidebar and the list, from the local copy                                                                             |
| Find a document by a word in its details or its text        | The search field, on every keystroke, also offline                                                                        |
| Read the original                                           | PDFKit in the window, Quick Look with Space, the default application with Return                                          |
| Read and copy the details (amount, due date, IBAN, numbers) | The inspector, and the amount in the list's row                                                                           |
| Read the extracted text                                     | The Text tab of the reader                                                                                                |
| Take a document elsewhere                                   | Drag to Finder or another application, Share, Export                                                                      |
| See what arrived                                            | Recently Added, the Arriving section on top of the list, and the five newest documents in the menu bar menu              |
| Collect from folders                                        | Everything the agreed design gives the collector                                                                          |
| Know what needs a decision                                  | Needs Attention, the menu bar glyph, and a notification when a folder's survey finishes or the archive refuses the token |

Each of the following stays in the browser, and the window has Open in Browser where a person would look for it, so nothing is a dead end.

- **Revising a document's details, deleting it, and retrying a failed one.** They need `modify` and `administer`, and members can issue only tokens of the levels `ingest` and `read` (`issuableLevels` in `src/authentication/api_tokens.ts`). A read-only copy needs no rules for edits made on two devices.
- **Renaming, merging, and deleting senders, categories, and tags.** Housekeeping a few times a year. The application shows the result within a minute.
- **Tokens and connected clients.** Administration of the archive, not use of it.
- **Uploading by hand.** A person puts the file into a collected folder. A drop on the window needs a path the collector's settled behaviour does not have, because a person's upload brings a deleted document back and a collector's never does.
- **Filters by date range and amount.** The list is grouped by month, the order can be changed, and the search finds amounts.

Deferred to a later version: the unread dot with Mark All as Read, notifications for new documents, search of the archive by meaning (`POST /api/v1/searches`), thumbnails of images bounded on the server, "keep every original on this Mac", editing, deleting, retrying, uploads by hand, taxonomy maintenance, and a sign-in through the browser.

### Names

No installed copy exists, so nothing is carried over.

| Thing                                                                                         | Today                                                     | In this design                                                                                                                |
| --------------------------------------------------------------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| The application                                                                               | Schublade                                                 | Schublade                                                                                                                     |
| Bundle identifier                                                                             | `org.schublade.application`, `.development` for Debug     | `org.schublade.application`, and `org.schublade.application.development` for Debug                                            |
| The workspace directory                                                                       | `native_client/`                                          | `native_client/`                                                                                                              |
| Shared access to an archive: address, credential, credential store, HTTP exchange, conditions | crate `archive_access`                                    | crate `archive_access`                                                                                                        |
| The local copy                                                                                | none                                                      | crate `archive_replica`, file `replica.sqlite`                                                                                |
| The collector                                                                                 | `collection_core`, `collection_command`                   | unchanged                                                                                                                     |
| The archive for tests                                                                         | `collection_core/src/scripted_archive.rs`                 | crate `scripted_archive`, which serves every route over HTTP                                                                  |
| The bindings                                                                                  | `application_bindings`, `application_bindings_generator`  | `application_bindings`, `application_bindings_generator`                                                                      |
| The Mac project                                                                               | `native_client/macintosh_application`, `Schublade`        | `native_client/macintosh_application`, product and scheme `Schublade`                                                         |
| The Worker's module for bearer-token clients                                                  | `src/collection_protocol/`                                | `src/client_protocol/`                                                                                                        |
| The journal                                                                                   | none                                                      | tables `change_journal` and `change_journal_identity`, module `src/client_protocol/change_journal.ts`                         |
| On disk                                                                                       | `collector.sqlite` under the bundle identifier            | `~/Library/Application Support/<bundle identifier>/` with `collector.sqlite` and `replica.sqlite`                             |
| Cache                                                                                         | none                                                      | `~/Library/Caches/<bundle identifier>/` with `originals/` and `thumbnails/`                                                   |
| Keychain service                                                                              | the bundle identifier                                     | the bundle identifier, so one item holds the one token                                                                        |
| Tauri application and React window                                                            | none                                                      | deleted in commit `1f9ce3a`                                                                                                   |

The word "collector" stays for the part that collects, in code and in the notes. The interface says "Folders on This Mac".

### The window

One window, restored where it was. Default size 1340 by 820 points, minimum 900 by 560. A split view of four parts under one unified toolbar:

1. **The sidebar**, 214 points, collapsible.
2. **The document list**, 330 points.
3. **The reader**, the rest, at least 480 points.
4. **The inspector**, 250 points, shown by default from a window width of 1280 points and toggled with Option-Command-I. It collapses first when the window narrows.

A page that is not about documents, such as a folder or Needs Attention, takes the place of the list, the reader, and the inspector together.

This is Mail's shape, for Mail's reason. The commonest act is to walk a list with the arrow keys and read each item as it is selected. Finder contributes Quick Look, dragging out, and the inspector's file facts. Photos contributes the grouping by month and the status line at the foot of the sidebar. Notes contributes the search that shows the matching passage in each row.

#### The sidebar

```text
Library
	All Documents            1,508
	Recently Added
	Arriving                     2      only while the archive reads a document
	Needs Attention              2      only while something does
People
	Household                  611
	Jonas Becker               402
Categories
	Invoice                    412      most documents first
Tags
	strom                       38
Folders on This Mac
	Downloads                   ✓       collecting
	Paperwork                   !       waits for a decision
	Scans                       ⌛      being surveyed
	Add Folder…
────────────────────────────────
✓ Up to date · 14:02                  the status line
```

- The sections collapse, and the application remembers it. Categories and tags show only those with a document.
- Senders have no section, because an archive has hundreds. A sender is reached by typing its name, or by clicking it in the inspector, which lists that sender's documents with the sender as the window's title and a back arrow.
- Arriving and Needs Attention appear only while they hold something.
- The status line says one thing, by this precedence: a refused token, "Offline · updated 13:40", "Loading · 500 of 1,508" with a progress bar during the first fill, "Uploading 2 files", and otherwise "Up to date · 14:02". Clicking it synchronizes.

#### The document list

- A view-based `NSTableView` with one column and fixed row heights, 68 points for a document and 26 for a heading. Fixed heights let the table place 50,000 rows without measuring any. Measured on the Mac on 2026-11-22 in an offscreen window, the table loaded 50,000 rows in 1.5 ms and made 11 row views.
- A row shows a picture of the first page (40 by 52 points), the title in semibold, the date and the amount when the document has one at the trailing edge, the sender, and a third line: the summary, the matching passage during a search, the arrival in the accent colour while the archive reads the document, or the failure in red.
- **Order.** By the date on the document, newest first, under month headings that float, with an Arriving section on top for documents still in ingestion. View > Sort By offers Date Added, Title, and Sender. Recently Added is always by arrival.
- **Pictures** load when a row appears, are decoded off the main thread at the row's size, and are kept in memory. A row without a picture shows the document glyph.
- **Changes arrive in place.** When the copy changes, the list receives the difference between its listing and the new one, and removes, inserts, and redraws exactly those rows inside one update, which keeps the selection and the scroll position. Measured on the Mac on 2026-11-22, 300 removals and 200 insertions in a table of 50,000 rows took 1.2 ms and kept the selection on the same document.

#### The reader

- A header with the title and one line of sender, date, and pages, with a segmented control for Original and Text at its trailing edge.
- **Original.** A `PDFView` for a PDF, continuous and sized to the width. A magnifying scroll view for an image. For an email the archive has not printed yet, a sentence in place of the page.
- **Text.** The extracted Markdown as selectable text.
- During a search the reader highlights the search words with `PDFDocument.findString` where the PDF has a text layer.
- An original that is not on this Mac while the archive does not answer shows "The Original Is Not on This Mac" with Try Again. The inspector and the Text tab still work.
- Nothing selected shows "No Document Selected".

#### The inspector

- **Details**: sender, category, person, date, then each extracted field with its label (Amount, Due, IBAN, Customer, Invoice, Policy). A value is selectable, and a hover shows a copy control that copies the plain value, such as an IBAN without spaces. Sender, category, and person are links that list their documents.
- **Tags** as chips, each a link.
- **Summary.**
- **File**: kind, pages, size, the day it was added, and Open in Browser.

#### Search

- One `NSSearchToolbarItem`. Command-F focuses it and Escape clears it.
- It searches the local copy and filters the selected sidebar entry. In a narrower entry the list ends with a row "Search All Documents".
- Results come in two sections, each newest first. The first holds the documents in which every term matched the title, the sender, the category, the tags, the person, the extracted fields, or the summary. The second holds the documents whose text alone matched. [The local copy](#the-local-schema-and-search) says what each part finds.
- Offline the search works unchanged.
- A new document is found by its details as soon as the archive has classified it, and by its text once the application has fetched the text. While texts are still being fetched after the first fill, the list's foot says "Searching the text of 1,200 of 1,508 documents".

#### First run and empty states

- **No archive connected.** The whole window is the form: address, token, Connect. A refusal appears under the fields as one sentence.
- **The first fill.** The main window appears at once, the list grows as pages arrive, and the status line counts. The journal delivers the newest documents first.
- **An empty archive.** "No Documents Yet", with "Add a folder, and Schublade archives what is in it" and an Add Folder button.
- **An archive too old for the library.** "Update your archive to use the library" in place of the list. Folders keep collecting, because the collector's routes are older.
- **The start failed.** The start failure screen of the agreed design.

#### The collector's place

- Each folder is an entry under Folders on This Mac with its state glyph. Its page is the page of the agreed design: the survey's progress, the confirmation, or the collecting page with the uploads from that folder. A page is at most 680 points wide and centred.
- The confirmation is a page, not a sheet, so a person can leave it, read a document, and come back. It keeps its two groups, "The files already there" and "From now on". The second group always reads that every new PDF, JPEG, PNG, or WebP file in the folder uploads automatically and that the application does not ask again for this folder.
- **Needs Attention** lists a folder awaiting its decision, a folder that cannot be read, a refused token, and refused files, and below them the documents whose ingestion failed, each with Open in Browser.
- A folder's recent uploads are document rows. Clicking one selects the document in the library.

#### Settings

A separate window with three toolbar tabs, opened with Command-Comma.

- **General**: Open at Login, Show in Menu Bar.
- **Archive**: the connected host, what the token permits, a field for a new token, Open Archive in Browser.
- **Storage**: the most space for originals (1, 2, 5, or 10 GB, or no limit, 2 GB by default), the space used, and Remove Downloaded Originals.

#### Keyboard

| Key                       | Does                                         |
| ------------------------- | -------------------------------------------- |
| Command-F                 | Search the library                           |
| Up and Down               | Walk the list, the reader follows            |
| Space                     | Quick Look of the selected document          |
| Return, or a double click | Open the original in its default application |
| Command-1, Command-2      | Original, Text                               |
| Option-Command-I          | Show or hide the inspector                   |
| Control-Command-S         | Show or hide the sidebar                     |
| Option-Command-B          | Open the document's page in the browser      |
| Shift-Command-E           | Export the original                          |
| Command-C                 | Copy the selected document as a file         |
| Command-R                 | Synchronize now                              |
| Shift-Command-O           | Add a folder                                 |
| Command-Comma             | Settings                                     |

Tab moves between the sidebar, the list, and the reader. Every command is in the main menu, so VoiceOver and the keyboard reach everything.

#### Dragging a document out

A list row and the reader's page drag as a file promise (`NSFilePromiseProvider`). The promised name is the one the core suggests, such as `2026-09-22 Stadtwerke Talbrück Electricity Annual Statement.pdf`. On the drop the application writes the cached original, or fetches it first, and a drop that cannot be fulfilled shows the reason. Share and Export use the same file. Quick Look and the default application open the cached file itself, which is read-only.

### The menu bar item, the Dock, and notifications

The menu bar item has six glyphs, drawn in code as template images from the drawer's geometry, in this order of precedence:

1. `attentionRequired`: the start failed, the token is suspended, a folder awaits its decision, or a folder cannot be read.
2. `archiveNotConnected`.
3. `archiveUnreachable`: unreachable, deferred, or checking.
4. `submitting`: an upload is in flight. Eight frames show a sheet that sinks into the drawer.
5. `resting`.
6. `starting`, before the first status.

The glyph speaks only for this Mac. A failed document in the archive does not turn it to attention, or one unreadable scan would mark the menu bar for good. A timer in the common run loop modes swaps the frames, and it exists only while an upload is in flight. The animator finishes the cycle it began, so a short upload shows one whole motion. Reduce Motion shows one still frame. Core Animation is not used, because layer contents bypass the template tint.

The menu is a real `NSMenu`:

```text
Up to date · 14:02                        the status line's sentence
Uploading Tax assessment 2025.pdf         while something is in flight
──────────────
Paperwork waits for your decision         each attention item of the collector, opens its page
──────────────
Recently Added
	Frischemarkt Receipt                    the five newest documents of the archive;
	Account Statement October 2026          choosing one opens the window on that document
──────────────
Open Schublade
Add Folder…
Settings…
Quit Schublade
```

The application is a regular application with a Dock icon while its window is open, and an accessory without one while it is closed. A start at login puts no icon into the Dock. Closing the window does not quit, and the collector goes on. Command-Q quits, as everywhere. The first time a person quits while a folder is collected, an alert says "Schublade stops collecting when it quits" and offers Quit and Close Window, with a checkbox to not ask again. With the menu bar item switched off and the window closed, the application runs unseen, and opening it again shows the window.

The first version notifies through `UNUserNotificationCenter` for two events. One says that a folder's survey finished and waits for a decision ("Paperwork is ready. 930 files wait for your decision."), and its click opens that folder's page. The other says that the archive refused the token. The application asks for the permission when the first folder is added, with the reason in the sentence above the system's prompt, and never at launch. New documents cause no notification.

Schublade keeps the drawer, its blue as the accent colour, and every sentence of the collector's wording. Fonts, controls, spacing, and badge colours are the system's.

### The Rust crates and what they share

```text
native_client/
	archive_access          address, credential, credential store, HTTP exchange, conditions, the authorization read
	collection_core         the collector, unchanged but for its imports
	archive_replica         the local copy: store, reader, machine, coordinator, search, cache
	scripted_archive        one model behind both cores' traits; scripted-archive-server serves every route over HTTP
	collection_command      schublade-collector
	application_bindings    UniFFI: the root, Library, Collector
	application_bindings_generator
	macintosh_application   the Xcode project
```

`collection_core` and `archive_replica` depend on `archive_access`, and neither depends on the other (per separate-before-serializing-shared-state). The two cores share no file and no thread. They share values: the address, the credential, the HTTP exchange, and the classification of an archive's answers. Each core keeps its own observation of the archive, and `application_bindings` derives the one `ArchiveConnection` a screen shows. The collector's connection machine stays in its coordinator, because moving it would reopen settled behaviour for no visible gain.

`archive_access` holds what moves out of `collection_core`, unchanged in behaviour:

- `ArchiveAddress`, an `https://` origin (or `http://` for a local server), with `document_page` as the one place a link into the archive is composed.
- `ArchiveToken` (was `IngestToken`, because the token also reads), never logged, stored in a database, or serialized. `ArchiveCredential` is an enum with one variant, `ApiToken(ArchiveToken)`, so a grant from a sign-in through the browser becomes a second variant without a change to any caller.
- `CredentialStore` with `KeychainCredentialStore` and `FixedCredentialStore`, and `RememberingCredentialStore`, which reads its inner store once per origin, so both cores cause one Keychain read and at most one prompt.
- `DocumentIdentifier` and `ContentDigest`.
- `ArchiveExchange`, the authorized exchange over `ureq`. It adds the `Authorization` header, bounds the answer, and turns 401, 403, 500, 503, a timeout, and a failed connection into an `ArchiveCondition`, so no route repeats that.
- `ArchiveCondition`, which gains `RouteUnknown` for a 403 without `application/problem+json`. Such an answer means the path fell through to `requireAccess` and the archive is older than the route. `parse_retry_after`.
- `read_authorization`, the one request of `GET /api/v1/authorization`, which answers an `ArchiveAuthorization` with the journal's identifier, the token's description, its `PermissionLevel`, whether it is restricted, and the scope digest. It replaces `HttpArchiveClient::verify_credential`, the lookup of the all-zero digest.

`archive_replica` is shaped like `collection_core`, so a contributor who knows one knows the other.

| Module                       | Holds                                                                                                                                   |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `lib.rs`                     | `Replica`, `ReplicaSettings`, `ReplicaEvent`, `ReplicaFault`, `ReplicaStatus`, `ReplicaFacets`, `DocumentDetail`                         |
| `replica_records.rs`         | `JournalCursor`, the five record types, `DocumentCondition`, `JournalPage`, `RemovedRecord`                                              |
| `replica_synchronization.rs` | `SynchronizationState`, `advance_synchronization`, `SynchronizationTiming`: the pure machine                                             |
| `replica_store.rs`           | The one SQLite file and the only module with SQL: `apply_page`, `discard`, the listing, search, and facet queries                       |
| `archive_reader.rs`          | `ArchiveReader` and `HttpArchiveReader`. No wire type leaves it                                                                          |
| `replica_coordinator.rs`     | The owner thread: the machine's effects, the text lanes, the status revisions                                                           |
| `document_listing.rs`        | `LibraryScope`, `ListingRequest`, `DocumentListing`, `listing_difference`                                                               |
| `search_expression.rs`       | A person's text as the two FTS5 expressions                                                                                              |
| `representation_cache.rs`    | Content-named files, the download gate, eviction by last use                                                                             |
| `migrations/0001_replica.sql` | The schema. Another `user_version` is a new fill                                                                                        |

One thread, the replica's coordinator, owns the write connection and the machine. Every read of `Replica` uses a read connection, which WAL never blocks on the writer. Work besides paging is derived, never queued, as in the collector. The archived documents without their text are fetched newest first by two lanes and written by the coordinator. `JournalCursor` wraps the text the archive sent and offers no arithmetic.

`scripted_archive` continues the core's module of that name as a crate. One model keeps records, contents, and a journal by the Worker's rules, implements both cores' client traits for scenarios, and answers scripted failures. `scripted-archive-server` serves every route over `tiny_http` for the end-to-end test, so an upload through the collector appears in the journal.

### The local schema and search

The device holds two SQLite files, one per core. `collector.sqlite` holds what cannot be had again: enrolled folders, decisions, receipts. `replica.sqlite` holds a copy, which can be deleted at any moment. That one property removes a class of design. The copy has no schema migrations after its first, because another version is a new fill. A file SQLite cannot read is replaced, and a replaced journal or another scope empties it.

```sql
CREATE TABLE mirror (
	singleton           INTEGER PRIMARY KEY CHECK (singleton = 1),
	archive_origin      TEXT NOT NULL,
	journal_identifier  TEXT NOT NULL,     -- from GET /api/v1/authorization
	scope_digest        TEXT NOT NULL,     -- from GET /api/v1/authorization
	permission_level    TEXT NOT NULL,     -- lets the start connect the collector after a crash
	journal_cursor      TEXT,              -- the cursor of the last applied page, as the archive sent it
	fill_complete       INTEGER NOT NULL DEFAULT 0 CHECK (fill_complete IN (0, 1)),
	synchronized_at     INTEGER,           -- seconds since 1970 of the last complete page
	content_revision    INTEGER NOT NULL DEFAULT 0
);
```

The record tables mirror the journal's records: `members`, `senders`, `categories`, `tags`, `documents`, `document_tags`, and `extracted_fields`. A document holds the identifiers of its sender, category, and member, and names join at query time. A reference becomes null when its record is removed (`ON DELETE SET NULL`), and a document's links and fields go with it (`ON DELETE CASCADE`). `documents.status` has no CHECK, so a status a newer archive adds is stored and shown as arriving. `documents.person_assignment` is `household`, `member`, or `unassigned`, with the member exactly when `member`. `listing_date` is `coalesce(document_date, date(created_at, 'unixepoch'))`, the browser's order. `extracted_texts` holds the Markdown of each archived document with the `original_sha256` it was fetched for. An archived document whose row is missing, or names another digest, awaits its text.

Search is two FTS5 tables, chosen by a probe on Linux on 2026-11-22 over 5,000 synthetic German documents with a body of about 8 KB each:

- `document_detail_search` over the title, the sender, the category, the tags, the person, the extracted fields, and the summary, with `tokenize = 'trigram remove_diacritics 1'`. Trigrams find a term inside a compound, so "versicherung" finds "Haftpflichtversicherung". A trigram matches only a term of at least three characters.
- `document_text_search` over the extracted text, contentless (`content = ''`, `contentless_delete = 1`), with `tokenize = 'unicode61 remove_diacritics 2'` and `prefix = '3'`. It matches words and word beginnings, and the passage comes from `extracted_texts`.

Ranking is by match class, not by bm25. Documents whose every term matched the details come first, then documents that matched in the text alone, each class newest first. For paperwork the newest of several equal matches is nearly always the one sought. A compound inside the body text, such as "rechnung" in "Stromrechnung", is found only by the archive's own search, which the first version leaves to the browser.

In that probe the split layout filled in 3.1 s into 93.9 MB with the texts, and answered the four sample queries in about 20 ms or less ("versicherung" 19.9 ms in the details and 0.1 ms in the text). One trigram table over everything took 224.5 ms for a common word and 187.4 MB. The probe's vocabulary had 65 words, so real German text indexes larger. Measured with the words-only layout on the same day: a listing of 5,001 rows in date order read into memory in 13 ms.

### The synchronization as a state machine

`advance_synchronization(state, input, attendance, now, timing)` is pure and total, with no wildcard arm, in the manner of the collector's four machines.

| State             | Meaning                                                                                                         | Leaves on                                               |
| ----------------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `Disconnected`    | No archive. The store is empty                                                                                   | `ConnectionEstablished`                                 |
| `Filling`         | The first fill, `fill_complete` false in the store. Pages back to back                                          | A complete page                                         |
| `Following`       | The copy held everything at `synchronized_at`. Waits                                                             | A wake, or the deadline                                 |
| `CatchingUp`      | A wake or a deadline, or a page said more follow. Pages back to back                                             | A complete page                                         |
| `Unreachable`     | A failure that can pass. Retries after 5 s, tripled to at most 5 min, or after a 503's `Retry-After`            | A page, or a person's wake, which retries at once       |
| `Suspended`       | 401, or a 403 with a problem document. Requests nothing                                                          | `ConnectionEstablished`, which a new token causes       |
| `ArchiveOutdated` | The archive lacks the routes (`RouteUnknown`). Asks hourly                                                       | A page                                                  |

Any state on `JournalReplaced`, a 410, discards the copy and fills. The cursor is not in the machine. The store holds it, written in the transaction of the page that produced it, and `apply_page` applies only while the stored cursor equals the one the page was requested after. The published `LibraryCopy` (`Absent`, `Filling`, `Complete`) derives from this state in the bindings, and whether the archive answers is said once, in `ArchiveConnection`.

The machine requests pages at the start, on a connection, when the application comes to the front, on wake from sleep, when the collector's archive accepted a document, every 5 seconds while a document is in ingestion, every 60 seconds while a window shows the library, and every 15 minutes otherwise. One request reads one index range of the journal. A push channel under `/api/v1` would be a later, compatible addition.

### Representations

An original is kept as `originals/<sha256>.<extension>` and a thumbnail as `thumbnails/<sha256>`, both under the cache directory. The archive never changes the bytes of a content, so a file named by its digest never goes stale. An original is verified against its digest after download and never revalidated. The directory is its own index. No table lists the files, so none can disagree with them, and the system may empty the directory at any time. A download runs on the calling thread of the `blocking` pool, at most four at once, into a temporary file that is renamed into place, so two downloads of one content are harmless (per make-operations-idempotent). After a download, originals are removed, least recently opened first, until they fit the limit, and a file handed out in this run is never removed.

A document whose digest is still null is fetched when shown and not kept. The text of a document is fetched once, when it is first seen archived, and again only when its `original_sha256` changes. The client reads at most 1 MB of a thumbnail and shows the glyph for a larger one, because the archive answers an image original as its own thumbnail until bounded thumbnails land.

### The bindings

#### What stays from the agreed boundary

- UniFFI 0.32.2 with proc macros in library mode. `application_bindings_generator` holds `uniffi-bindgen-swift` at the same pinned version, so the `cli` feature stays out of the static library. The cores gain no attribute and no dependency.
- **Following by revision.** `status_after(revision)` waits before it reads, for an announcement above the caller's revision or for the coordinator's end, and then reads. `None` reads at once. The listener is registered before each read, so no announcement falls between a read and the wait. A caller that passes back each answer's revision never sees an older status after a newer one. No foreign trait exists, so no Rust thread calls into Swift.
- **Blocking.** Every `async` export wraps its core call in `blocking::unblock`. The thread that polls the future, which can be the main thread, never waits on a coordinator, the network, or the Keychain.
- **Composition.** The second start after an unreadable database, the connection flow, and the mapping of start failures live here.
- **Derivation.** `published_status.rs` and `published_library.rs` define each status as an application shows it, and `publish` is the one conversion from each core's status. It destructures every core struct without `..` and matches every core enum without a wildcard arm, so a new field or variant in a core fails to compile here until someone decides what an application shows for it.
- **One refusal type per command.** A refusal that names a folder carries its `FolderReference`. Each Swift wording function is one total `switch` with no default sentence.
- Identifiers are records with one field, so Swift gets a distinct type for each and cannot pass a tag where a sender is meant. Times cross as `SystemTime` and arrive as `Date`.

#### The root and the connection flow

```rust
pub async fn start_application_core(configuration: ApplicationConfiguration) -> Result<Arc<ApplicationCore>, ApplicationStartFailure>;

impl ApplicationCore {
	pub async fn connect_archive(self: Arc<Self>, address: String, token: String) -> Result<(), ConnectionRefusal>;
	pub fn library(&self) -> Arc<Library>;
	pub fn collector(&self) -> Option<Arc<Collector>>;      // None without a collector, as on the iPhone
	pub fn interface_attended(&self, attended: bool);       // a window shows the library
	pub fn system_resumed(&self);
	pub async fn shutdown(self: Arc<Self>);
}
```

`ApplicationConfiguration` holds the data directory, the cache directory, the storage limit for originals, the `CredentialStorage` (`Keychain { service_name }`, compiled only for macOS, or `ProcessMemory`), and `collection: CollectionPlacement` (`Collector` or `Absent`). The start opens the collector on `collector.sqlite` when placed, the replica on `replica.sqlite`, both over one `RememberingCredentialStore`, and gives the replica the archive the collector is connected to. A replica file that cannot be opened is no failure of the start, because the replica creates it anew.

`connect_archive` is the one connection flow, for the first connection and for a replaced token. Every step is idempotent:

1. Parse the address. An invalid one answers `AddressInvalid`.
2. Read `GET /api/v1/authorization` with the token. A failure answers its refusal, and nothing is stored.
3. Refuse with `ArchiveDiffers { connected_host }` while the collector holds folders or contents of another origin. The collector stays with its first archive.
4. Store the token under the origin.
5. Connect the collector when a collector exists. Every token may add documents, because `ingest` is the lowest level.
6. Attach the replica when the token's level is `read` or above. It keeps its copy when the journal's identifier and the scope digest equal the ones it was filled under, and empties it otherwise.

A token that may only add documents connects the collector only, and the library says that the token cannot read. The start repairs a crash between the two halves. When the mirror records an archive whose permission allows ingest and the collector has none, it connects the collector with the stored credential. Unit 1's exported `start_collector` and `Collector::connect_archive` stop being exported, so there is one way to start and one way to connect.

`ConnectionRefusal` keeps unit 1's cases (`AddressInvalid`, `TokenRefused`, `TokenInsufficient`, `ArchiveUnreachable`, `ArchiveUnavailable`, `ArchiveFailed`, `NotAnArchive`, `ArchiveDiffers { connected_host }`, `CredentialStorageFailed { detail }`), gains `ArchiveOutdated`, and its `Collector { fault }` becomes `Application { fault: ApplicationFault }`. `ApplicationFault` (was `CollectorFault`) is `Stopped`, `StoreFailed { detail }`, or `Unexpected { detail }`, and every call can answer it. `ApplicationStartFailure` is unit 1's `CollectorStartFailure` (`DataDirectoryUnavailable`, `DatabaseInUse`, `DatabaseNewerThanApplication`, `DatabaseUnusable`, `WatcherUnavailable`) with `CacheDirectoryUnavailable { detail }` and `Unexpected { detail }`.

#### One status per part

```rust
impl Library {
	pub async fn status_after(self: Arc<Self>, revision: Option<u64>) -> Result<LibraryStatus, ApplicationFault>;
	pub async fn list_documents(self: Arc<Self>, request: ListingRequest, preceding: Option<Arc<DocumentListing>>) -> Result<ListingAnswer, ApplicationFault>;
	pub async fn facets(self: Arc<Self>) -> Result<LibraryFacets, ApplicationFault>;
	pub async fn document(self: Arc<Self>, document: DocumentIdentifier) -> Result<Option<DocumentDetail>, ApplicationFault>;
	pub async fn original(self: Arc<Self>, document: DocumentIdentifier) -> Result<LocalFile, RepresentationRefusal>;
	pub async fn thumbnail(self: Arc<Self>, document: DocumentIdentifier) -> Result<Option<LocalFile>, RepresentationRefusal>;
	pub async fn extracted_text(self: Arc<Self>, document: DocumentIdentifier) -> Result<String, RepresentationRefusal>;
	pub fn synchronize(&self);
}

impl Collector {
	pub async fn status_after(self: Arc<Self>, revision: Option<u64>) -> Result<CollectorStatus, ApplicationFault>;
	pub async fn enroll_folder(self: Arc<Self>, root: String) -> Result<FolderReference, EnrollmentRefusal>;
	pub async fn withdraw_folder(self: Arc<Self>, folder: FolderIdentifier) -> Result<(), WithdrawalRefusal>;
	pub async fn decide_backlog(self: Arc<Self>, folder: FolderIdentifier) -> Result<(), DecisionRefusal>;
}
```

`Library::status_after` and `Collector::status_after` each follow their own revision. The iPhone has no collector, and the collector's announcements every 250 ms during an upload stay off the library's loop. `CollectorStatus` keeps everything of unit 1 but `archive`. The connection is published once, in `LibraryStatus`:

- `LibraryStatus` holds `revision`, `archive: ArchiveConnection`, `copy: LibraryCopy`, `content_revision`, and `counts: LibraryCounts` (documents, in ingestion, failed, awaiting their text).
- `ArchiveConnection` is `NotConfigured` or `Configured { origin, host, condition, permission, restricted }`. `ConnectionCondition` keeps unit 1's `Connected`, `Checking`, `Unreachable { since }`, `Deferred { until }`, and `Suspended { reason }`, and gains `ArchiveOutdated`. `ArchivePermission` is `ReadOnly` or `ReadAndCollect`. The bindings derive it from the replica's observation and the collector's.
- `LibraryCopy` is `Absent`, `Filling { received, remaining }`, or `Complete { synchronized_at }`. It has no "unreachable" case, and `ArchiveConnection` has no "filling" case.

`content_revision` rises only when a record or a text of the copy changed. A pane reads its listing, facets, or document again exactly when `content_revision` differs from the one it read at, so a status that only moved the progress never makes a list read itself again.

#### The listing stays in Rust

`DocumentListing` is an immutable object that holds the rows of one request at one content revision: `row_count()`, `rows(first, count)`, `position_of(document)`, `document_count()`, and `content_revision()`. A table view reads row windows from memory on the main thread and receives a `ListingDifference` (`removed_positions` in the preceding listing, `inserted_positions` and `revised_positions` in the new one), never the listing.

| Access                      | Path                                                                       | Measured on 2026-11-22                                                                                     |
| --------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Show a scope                | `list_documents(request, None)`: one SQL query off the main thread         | 13 ms for 5,001 rows on Linux                                                                              |
| Draw a row                  | `rows(first, 64)` from memory                                              | 235 µs for 64 rows of a 50,000-row listing through UniFFI on the Mac's main thread, an upper bound under load |
| The copy changed            | `list_documents(request, Some(preceding))`: the new listing and the difference | 1.2 ms in the table for 300 removals and 200 insertions among 50,000 rows                              |
| Open a document             | `document(id)`: one row with its names resolved                            | One indexed read                                                                                           |
| Sidebar counts              | `facets()`, read again when the content revision changes                   | Four grouped queries over indexes                                                                          |

`ListingRequest` is `Browse { scope, order }` or `Search { scope, text }`, so a search with an order cannot be asked. `LibraryScope` is `AllDocuments`, `RecentlyAdded` (added within 30 days, newest arrival first), `InIngestion`, `Failed`, `Household`, `Member`, `Category`, `Tag`, or `Sender`. `ListingOrder` is `DocumentDate`, `Addition`, `Title`, or `Sender`. A `ListingRow` is `Heading { heading }` or `Document { row }`, and `ListingHeading` is `Arriving`, `Period { year, month }`, `DetailsMatched`, or `TextMatched`. A `DocumentRow` holds the identifier, the condition, the title, the sender's and the category's names, the document date, the arrival, the summary, the amount when the document has one, and the passage of a search.

`DocumentCondition` is `InIngestion { stage }`, `Archived`, or `Failed { reason }`, so a failure reason exists exactly when the document failed. `IngestionStage` has an open case, `Other`, for a status a newer archive adds, and `FailureReason` has `Other` for the same reason. `DocumentDetail` has 16 members, each something the inspector shows: the identifier, the condition, the title, the date, the sender, the category, the person (`None` while unassigned), the tags, the summary, the fields with a typed `FieldValue` (`Text`, `Number`, `Date`), the `OriginalKind`, the size, the pages, the arrival, the document's page in the browser, and the suggested file name. A sender, a category, a person, and each tag arrive as a `NamedScope`, so a click on one changes the listing.

`RepresentationRefusal` is `DocumentUnknown`, `NotAvailableYet` (an email not printed, or a text not extracted), `ArchiveUnreachable`, `CredentialRefused`, `ArchiveOutdated`, `ContentDiffers` (the archive sent other bytes than the record names, and nothing was kept), `StorageFailed { detail }`, or `Application { fault }`.

### The Swift modules and the owners of state

The generated Swift fails to compile in a module whose default isolation is `MainActor`, so it gets its own module. Presentation is a module that imports Foundation only, so no view logic can reach it.

| Target                         | Directory                         | Holds                                                                                                                                                                      |
| ------------------------------ | --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ApplicationBindings`          | `generated_bindings/`             | The generated Swift, with nonisolated default isolation. Git ignores it                                                                                                     |
| `ApplicationPresentation`      | `application_presentation/`       | Pure functions from the situation, the navigation, and the core's answers to `Equatable` values: the wording, `windowContent`, `statusItemPresentation`, `windowOpensAtLaunch` |
| `ApplicationInterface`         | `application_interface/`          | The AppKit application: the gateway, the controller, the window, the screens, the status item, and the controls                                                             |
| `Schublade`                    | `application/`                    | `main.swift`, the asset catalog, and the generated `Info.plist`                                                                                                             |
| `ApplicationPresentationTests` | `application_presentation_tests/` | Swift Testing, with no host application                                                                                                                                     |
| `ApplicationEndToEndTests`     | `application_end_to_end_tests/`   | One XCTest bundle that Xcode loads into the real application                                                                                                                |
| `InterfaceRenderer`            | `interface_renderer/`             | A command-line tool that writes every screen and glyph to PNG files                                                                                                         |

Directories use lower case with underscores. A Swift file bears the name of the type it declares. No Swift is shared with the iPhone application.

Every piece of state has one writer.

| State                                                                                    | Owner                                                                 | Kept in                                 |
| ---------------------------------------------------------------------------------------- | --------------------------------------------------------------------- | --------------------------------------- |
| The started core                                                                         | `ApplicationGateway`, the only type that calls `ApplicationBindings` | Memory                                  |
| The situation: starting, failed to start, running with the latest statuses, or stopped   | `ApplicationController`                                               | Memory                                  |
| The navigation: sidebar destination, search text, order, selected document, inspector    | `MainWindowController`                                                | Memory, saved with the window's state   |
| The listing shown and the row windows read from it                                       | `DocumentListModel`                                                   | Memory                                  |
| Decoded pictures of first pages                                                          | `PictureStore`                                                        | `NSCache`                               |
| Whether the menu bar item shows                                                          | AppKit, through `NSStatusItem.isVisible` under an `autosaveName`      | User defaults, written by AppKit        |
| Whether start at login was ever established, and the quit alert's "do not ask again"     | `ApplicationPreferences`                                              | User defaults                           |
| Start at login                                                                           | The system, through `SMAppService.mainApp`                            | Read on each activation                 |
| The token                                                                                | `archive_access`'s Keychain store                                     | The login Keychain                      |
| Folders, decisions, receipts                                                             | `collection_core`                                                     | `collector.sqlite`                      |
| The records, the texts, the cursor                                                       | `archive_replica`                                                     | `replica.sqlite`                        |
| Originals and thumbnails                                                                 | `archive_replica`                                                     | `~/Library/Caches/<bundle identifier>/` |
| The activation policy and the window                                                     | `MainWindowController`                                                | AppKit                                  |
| A form's text and the attempt in flight                                                  | That form's view controller                                           | Its fields                              |
| The animation's frame and timer                                                          | `StatusItemAnimator`                                                  | Memory                                  |

Data moves one way. `ApplicationController` stores the one `ApplicationSituation` and calls pure functions to `WindowContent` and `StatusItemPresentation`. Each controller has a `render` that takes its value and skips work when the value is unchanged. A library screen holds a `LibraryQueries` value and a collector screen a `CollectorCommands` value, each a protocol of `async` functions with typed throws, and nothing else of the application. The wording of `status_sentences.ts`, `backlog_confirmation_wording.ts`, `number_wording.ts`, and `time_wording.ts` in `collector/collection_interface/src/` carries over sentence for sentence. Commit `37f77e5` is the last that holds those files with their tests. The clock, the calendar, the locale, and the folder names enter through a `WordingContext`, so tests and the renderer fix them. A folder's name comes from `FileManager.displayName(atPath:)`, because Finder shows localized names such as "Dokumente". Pictures are decoded and PDFs opened off the main actor in `nonisolated` functions that return `sending` values. Measured on the Mac on 2026-11-22 under Swift 6 with complete strict concurrency and warnings as errors, a `PDFDocument` made off the main actor arrived on it, and a `CGImage` decoded with `CGImageSourceCreateThumbnailAtIndex` away from the main thread arrived with no Sendable diagnostic.

### Lifecycle

- `LSUIElement` starts the application with the Accessory policy, so a start at login shows no Dock icon. `MainWindowController` sets Regular when the window opens and Accessory when it closes.
- `LSMultipleInstancesProhibited` makes a second open arrive at the running application as a reopen, which shows the window. A process started outside Launch Services finds the first one with `NSRunningApplication` and ends. The collector's database lock stays the last guard.
- `SMAppService.mainApp` registers the login item on the first configured status, once. Afterwards the person decides.
- The launch origin comes from the launch Apple event in `applicationDidFinishLaunching`, an open-application event whose `keyAEPropData` is `keyAELaunchedAsLogInItem`. A login launch keeps the window closed only while the core runs and an archive is configured. A failed start or a missing archive opens the window even at login.
- The window becoming key or leaving the screen calls `interface_attended`. `NSWorkspace.didWakeNotification` calls `system_resumed`, and the application coming to the front calls `Library::synchronize`.
- Terminating answers `.terminateLater`, awaits `shutdown()`, and replies.

### The build

XcodeGen writes `Schublade.xcodeproj` from `native_client/macintosh_application/project.yml` on every script run, and git ignores the project. The `ApplicationBindings` target has a pre-build phase that runs `scripts/produce_application_bindings.sh`:

1. `cargo build -p application_bindings --target aarch64-apple-darwin` with the Xcode configuration's profile and `MACOSX_DEPLOYMENT_TARGET` equal to the Swift deployment target.
2. `uniffi-bindgen-swift` on that exact library.
3. Replacement of each generated file only when it changed.

The bindings are never committed. Generated Swift that differs from the linked library ends the application at launch with a checksum mismatch. Every executable links the Rust library with Security, CoreFoundation, CoreServices, and iconv, and a linker warning fails the build.

Every target uses the Swift 6 language mode, complete strict concurrency, and warnings as errors. SwiftLint in strict mode and SwiftFormat in lint mode run in the check. Custom SwiftLint rules refuse `import SwiftUI`, AppKit inside `application_presentation/`, a call of the bindings outside `ApplicationGateway`, `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency import`, `DispatchQueue.main`, and Interface Builder files.

The build is arm64 only, with macOS 14 as the deployment target. Only macOS 26 has been tested. Signing is ad hoc. `configuration/signing.xcconfig` includes an optional, ignored local file for the Developer ID identity and the team.

On the development server every Mac command runs through `scripts/execute_on_macintosh.sh`:

```bash
scripts/execute_on_macintosh.sh native_client/macintosh_application/scripts/check_application.sh    # the one check
scripts/execute_on_macintosh.sh native_client/macintosh_application/scripts/build_application.sh    # the application bundle
scripts/execute_on_macintosh.sh native_client/macintosh_application/scripts/render_interface.sh     # every screen and glyph as PNG files
```

`check_application.sh` runs the cargo checks, SwiftFormat, SwiftLint, the Release build of every target, the presentation tests, and the end-to-end test.

### Tests

The compiler carries most of the weight: exhaustive switches over generated enums, typed throws, `publish` without wildcards, and main-actor isolation. Each test covers something it cannot see (per test-behavior-not-implementation).

| Test                                                                                                                                                                    | Where                                              | Protects                                          |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------- |
| Every table is journaled or listed as not replicated, and every journaled table has its triggers after all migrations, split by `cf`'s own splitter                     | `change_journal.workerd.test.ts`                   | The journal's completeness, for good              |
| A client that pages through `reviseDocument`, `mergeTaxonomyRecords`, `deleteDocument`, and the ingestion workflow's writes ends with the listing's state              | `change_journal.workerd.test.ts`                   | The triggers against the real writers             |
| A restricted token: a document that leaves the scope is removed, no name outside it is sent, and a sender renamed while only a document outside the page refers to it is sent | `change_journal.workerd.test.ts`              | What a restricted token sees                      |
| The page a seeded archive answers equals `test_fixtures/client_protocol/changes_page.json`, and the Rust reader parses that file into the expected records             | workerd and `archive_replica`                      | One wire format for two implementations           |
| Every new route is admitted without Access, and a trailing slash, another case, and any unknown path under `/api/v1` stay behind it                                     | `request_dispatch.workerd.test.ts`                 | Fail closed                                       |
| A copy equals the archive after any interleaving of changes, pages, repeats, restarts, and a replaced journal                                                           | `archive_replica`, against `scripted_archive`      | No missed change, no resurrection, idempotent replay |
| The machine: a refused token requests nothing, and a person's wake retries at once                                                                                     | `archive_replica`, pure                            | The policy                                        |
| The difference of two listings, applied to the first, gives the second                                                                                                 | `archive_replica`, generated listings              | Every animated update of the list                 |
| A read for the current revision waits for the next change, the first read answers at once, and following never goes back                                              | `application_bindings`, for each part              | The loops every screen rests on                   |
| An ingest token connects the collector only, and another origin is refused while the collector holds records                                                          | `application_bindings`                             | The one connection flow                           |
| Shutdown ends every read, and every refusal of a core reaches the command that caused it                                                                                | `application_bindings`                             | Termination and the refusal mapping               |
| The confirmation's sentences, counts, and grouping; "everything is collected" only when true; the status line's sentence and precedence; the row's third line; which content shows; the glyph's precedence, the end of the animation, and Reduce Motion; which launch opens the window | `ApplicationPresentationTests` | What the application claims |
| Connect, see the corpus's documents, select one, read its original, enroll a folder, decide, see its documents arrive in the list                                       | `ApplicationEndToEndTests`                         | Everything together                               |

The end-to-end test runs over SSH. `xcodebuild test` starts the Debug application and loads the test bundle into it. The environment selects an isolated `ApplicationEnvironment`: a temporary data directory and cache directory, the token in process memory, preferences in a throwaway suite, and an inert login item. This switch exists only in Debug builds. The test presses controls through `InterfaceIdentifier`, passes a copy of `test_fixtures/collection_corpus/Downloads` in place of the folder panel, and talks to `scripted-archive-server`. The real bundle, the gateway, the bindings, both cores, FSEvents, and the HTTP client all run.

`InterfaceRenderer` builds the real view controllers from fixed situations and fixed listings and writes each screen, the menu's rows as text, and every glyph and frame, in both appearances, through the frame view with `cacheDisplay(in:to:)`. `PDFView` draws blank that way, measured on the Mac on 2026-11-22, so the renderer draws pages with `PDFPage.draw(with:to:)` in its place. The sidebar's and the toolbar's glass draw blank or black offscreen, so the renderer paints stand-ins. A person or an agent looks at the files. No test compares a picture, and no test calls a billed service.

### What only a session at the Mac's screen can verify

1. The glyph in the real menu bar, light and dark, its animation during an upload and during an open menu, and Reduce Motion.
2. The menu opening on a click and its rows updating while open.
3. The Dock icon and the main menu appearing with the window and leaving with it, and the quit alert.
4. The window in its key look: default buttons, the focus ring, the tab order, and VoiceOver.
5. The sidebar's and the toolbar's glass.
6. `PDFView` scrolling, selection, and the highlight of search words.
7. The search field's focus, its clear button, and typing speed against a real archive.
8. Quick Look, the file promise in Finder and Mail, and Share.
9. The notification's prompt and its click.
10. The folder panel and the privacy prompts for Downloads, Desktop, Documents, and a cloud folder.
11. Start at login: the entry under Open at Login with the name and the icon, a logout and login with no window, and the logged launch origin.
12. The Keychain prompt for the existing item, and the same after a rebuild.
13. A second copy of the application.

## Synthesis decision

Candidate 1 is the base. A judge on another model scored it 24 to 23 and named the same base. Its page is one snapshot that carries the records its documents refer to, one function says what a scope admits, a test reads `sqlite_master` and fails when a migration drops a trigger, and the listing stays in Rust.

From candidate 2, in order of weight:

1. **Two migrations.** drizzle-kit generates `0008_record_change_journal.sql` from `schema.ts` with the two tables. `0009_journal_record_changes.sql` comes from `drizzle-kit generate --custom` and holds the triggers, the identity row, and the backfill. One hand-written migration that also created the tables would make the next `pnpm database:generate` create them again, because drizzle-kit 0.31.11 writes the previous snapshot for a custom migration.
2. **`scope_digest`.** The authorization answer carries a digest of what the token may see. A client empties its copy when the journal's identifier or the scope digest differs from the one its copy was filled under, so a replaced token never keeps a copy filled under another scope.
3. **Search for German paperwork.** Trigrams over the details, words with prefix indexes over the text, ranking by match class.
4. **Wire details.** A tagged `person` object, a typed field value, an unknown status mapped to arriving, an unknown record kind skipped, no CHECK on the local status, and an open case in `IngestionStage`.
5. **The server code** of candidate 2 as the starting point of `src/client_protocol/`, with every list of identifiers bound as one JSON parameter through `json_each` and never `inArray` over a page.
6. **One start and one connection flow** on the root object.
7. **One status per part**, each with its own revision, and the connection published once, in the library's status.
8. **Product details.** The amount in a row, the Arriving section, and candidate 2's probe of the real migrations through `cf`'s own SQL splitter as the template for the journal's workerd test.

Rejected from candidate 2: taxonomy names visible to restricted tokens, which would widen what a restricted token reveals, while `archive_tools.ts` drops options with no admitted document today. Identifiers crossing the bindings with rows fetched asynchronously, because visible rows would need placeholders, and copying 50,000 identifiers measured 17.6 ms on the Mac against 235 µs for 64 rows from memory. An accepted gap after a database restore, because the one-statement rotation closes it. `clients/` as the directory name. Details above the PDF, because the inspector leaves the page the full height.

## Tradeoffs accepted

- We accept 21 triggers in a custom migration that drizzle-kit cannot see, in exchange for a journal no writer can forget. A workerd test that reads `sqlite_master` stands where drizzle's snapshot does not.
- We accept that a document is delivered again after writes a client does not read, such as `indexed_at`, in exchange for triggers without column lists.
- We accept that a client can miss intermediate states of a record, in exchange for a journal that holds one entry per record and needs no pruning.
- We accept tombstones kept for good, one journal row for each record ever deleted, in exchange for a protocol with no retention window.
- We accept that a restore of the database needs one SQL statement by hand, in exchange for not building a chain of hashes for an event that happens once in years.
- We accept two observations of the connection, merged where they are published, in exchange for leaving the collector's coordinator alone.
- We accept that the application learns of a document that arrived by mail up to 60 seconds late while its window shows, in exchange for no socket, no long request, and no change behind Access.
- We accept that the body text matches words and word beginnings only, in exchange for an index about half the size of one trigram table and a common word answered in milliseconds instead of a quarter second. The archive's search covers the rest.
- We accept that quitting stops collection, with one alert that says so, in exchange for a Command-Q that means what it means everywhere.
- We accept renaming `collector/` and the bindings crates right after units 1 and 2 landed, in exchange for names that say what the directory and the crates now hold.
- We accept that the first version cannot edit, delete, or upload by hand, in exchange for a version whose every screen is finished.
- We accept about 250 lines of conversion in each `publish`, in exchange for published types that hold no rule a Swift caller must remember.
- We accept two small crates, `blocking` and `event-listener`, in exchange for an application with no callback from a Rust thread and no revision rules of its own.
- We accept that UniFFI maps no Swift cancellation to Rust, so a waiting `status_after` ends only with a newer status or with `shutdown`.
- We accept that a debug static library is about 150 MB and that every executable links it, in exchange for bindings generated from the exact library on every build.
- We accept Keychain prompts after each ad hoc rebuild until a stable signing identity exists, in exchange for one credential store shared with the command-line program.
- We accept a Debug-only environment switch in the application, in exchange for an end-to-end check of the real bundle that never touches the Keychain.
- We accept that the window decision at a login launch rests on an Apple event property not yet observed under `SMAppService`. A wrong answer opens the window and never hides a failure.

## Alternatives considered

- **A cursor on `updated_at`.** No migration and no triggers. It loses changes within one second, loses deletions, and misses a category rename unless every writer remembers to raise the time. Its interface is as small as the journal's, and its hidden complexity is unsound.
- **An append-only log of operations** ("document X retitled", "tag A merged into B"). It exposes every kind of write to every client, grows without bound, and makes order within a page matter. The journal of present states hides all of that behind upserts.
- **A journal written by the Worker's code.** The same feed, but 34 write statements and every future one must remember it, and `cf d1` writes from outside the Worker. A trigger cannot be forgotten.
- **No copy: a native window over a listing API with paging.** Every scroll and keystroke becomes a request, nothing works offline, and the owner asked for a local copy.
- **One widened core crate.** One coordinator and one SQLite file for everything. It ties a disposable copy to state that must never be lost, puts page requests behind uploads on one thread, and makes the iPhone's reader carry the folder machine.
- **The whole listing to Swift, with a diffable data source.** The least Rust, but every change copies every identifier again, and row data needs a second path by identifier. The listing object answers both with one type.
- **One merged status for both parts.** One loop in Swift, but two revision sources merged into one, and a collector that announces every 250 ms during an upload would make the library's status cross the bindings as often.
- **A helper process that owns the collector.** Collection would survive Command-Q. It doubles the exported surface across a process boundary and gives two programs one database.
- **Swift owns the Keychain.** It duplicates the core's credential store for each platform and makes the token cross the boundary on every start.
- **A popover from the menu bar item.** Custom chrome for content a menu already holds, and awkward for the keyboard and VoiceOver.
- **SwiftPM alone, or a hand-kept project.** SwiftPM produces no bundle, no `Info.plist`, and no signature. A hand-kept project file cannot be reviewed as text.
- **A universal build.** The owner's Macs are Apple silicon. Release can gain an x86_64 slice later in `produce_application_bindings.sh`.
- **Sign-in through the browser as the first way to connect.** It needs the consent page and the OAuth provider's routes changed, and a session at a real screen to verify. The credential is an enum so that it becomes the second way.

## Implementation reconciliation

Unit 1, the bindings crate, landed as commit `7ce2f82` and accepted these changes on 2026-11-22.

- `status_after` waits before it reads. A call with a revision waits for an announcement above that revision, or for the coordinator's end, and then reads the status. The read-then-compare loop of the first sketch never waited, because the core counted every status read as a revision. Commit `510b5ae` stopped counting `ReadStatus` and `WaitUntilIdle`, so any number of callers can follow.
- The exported methods take `self: Arc<Self>`, so the closure given to `blocking::unblock` owns the object. Swift sees the same functions.
- The core sits in an `RwLock<Option<collection_core::Collector>>`. Every call holds the read lock while the core answers. `shutdown` takes the core out under the write lock and calls the consuming `shutdown(self)` on a blocking thread, and a second call finds nothing to do.
- `FolderStatus` has no `root` of its own, because its `FolderReference` carries it. `Activity::Listing` carries the `FolderReference`.
- `enroll_folder` and each refusal that names a folder read the status once more for the root, because the core stores the absolute path. A folder withdrawn in between answers the fault `Unexpected`.
- `CollectorFault` is an error type of its own, which `status_after` throws, and also the field of the four refusals. This design renames it `ApplicationFault`.
- `ArchiveDiffers` carries `connected_host`, and `host` keeps the port, as in `localhost:3000`.
- The `cfg`-guarded `Keychain` variant compiles and exports on Linux.

Unit 2, the Xcode project, landed as commit `94ca40c`. Its check took 27 s over SSH from a clean state and 8 s unchanged. It recorded these facts.

- Xcode keeps the hardened runtime under ad hoc signing in Release and drops it in Debug.
- cargo does not fingerprint `MACOSX_DEPLOYMENT_TARGET`, so a changed deployment target leaves objects built for the old version, and the link then fails. On 2026-11-22, `cargo clean --target aarch64-apple-darwin` for the bindings crate and `collection_core` cleared it.
- The generated Swift compiles as its own module only with `-parse-as-library`.
- The test target keeps nonisolated default isolation.

A review of the bindings crate found that timer and planning transitions in the collector's coordinator changed the status without a new revision, so a follower could keep an old status. The fix was written by another session while this note was written and landed as commit `37f77e5`.

The same review left three findings open, which [Open questions and risks](#open-questions-and-risks) carries. `CollectorStartFailure` has no case for a failure outside the core, so unit 2's gateway stops the application on one. `ApplicationStartFailure` therefore has `Unexpected { detail }`. One run of the corpus following test on the Mac failed once with different counts and passed on five reruns, and the cause is unknown.

Commit `1f9ce3a` deleted the Tauri application and its React window ahead of the order below, which planned unit D last. The workspace lost its default members, and the application's icon and menu bar glyph drawings moved to `macintosh_application`.

Under this design units 1 and 2 keep their behaviour and change their names in unit R1: `collection_bindings` becomes `application_bindings`, `CollectionBindings` becomes `ApplicationBindings`, `CollectorInterface` with `collector_interface/` becomes `ApplicationInterface` with `application_interface/`, `CollectorGateway` becomes `ApplicationGateway`, `CollectorSituation` becomes `ApplicationSituation`, `SchubladeCollector` becomes `Schublade`, and `produce_collector_bindings.sh` becomes `produce_application_bindings.sh`.

Unit S1, the journal, landed as commit `70144d1`. Unit S2, the client protocol, settled these points against `notes/client_protocol.md`, which now says the same.

- A page holds at most 250 journal entries today, the server's choice, which a client must not assume.
- A page without `after` holds removals too, so a fill and a catch-up read by one path.
- A cursor's number has at most 15 digits, so it stays below 2^53.
- `readJournalPage` reads the highest issued number as `max(sequence_number)` and counts the entries after the page's last entry in the same batch, which the wire carries as `remaining`.
- The entries of `changes` come in no promised order. The fixture test compares them keyed by record kind and identifier.
- `collection_protocol/` is part of `src/client_protocol/`: `client_paths.ts` holds the one route table with each route's method and level, and `client_requests.ts` the one gate. `deniedTagsAllExist` moved from `archive_tools.ts` to `document_listing.ts`, and `document_representation.ts` exposes `readStoredRepresentation` to both the browser's route and the client's.
- The representation routes and the authorization answer 400 to a query parameter, as every route of the protocol does. The collector's three routes do not check query parameters, as before.

A review of unit S2 on 2026-11-22 found that deploying it would let every token issued for a scanner read the whole archive, because the levels were ordered `read`, `ingest` and Settings issued only `ingest`. It changed these points, and `notes/client_protocol.md` says the same.

- The levels are ordered `ingest`, `read`, `modify`, `administer`. A token of level `ingest` adds documents and reads nothing. A token of level `read` reads the archive and adds to it, which the application needs for its library and its collector.
- `GET /api/v1/authorization` needs only `ingest`, so every token can ask what it may do. The changes and the three representations need `read`.
- Settings issues two kinds of token, "Scanner, script, or Shortcut: adds documents" (`ingest`) and "Schublade app: reads and adds documents" (`read`).
- `test_fixtures/client_protocol/authorization.json` now holds `"permission_level": "read"`, because its token, "MacBook of Jonas", reads the changes of the other fixture. `archive_access` must order `PermissionLevel` as `Ingest`, `Read`, `Modify`, `Administer`, the fixture test must expect `Read`, and the connection flow must attach the replica only for `read` or above.
- The collector's three routes answer a token with a restricted scope 403 with a problem document, because a collector must see every content. A restricted token therefore connects the library alone.
- `If-None-Match` is the one condition a representation honours. An original that R2 lacks answers 404 even to its own digest, and `If-None-Match: *` on an original answers 200.
- Every answer of the gate carries `Cache-Control: no-store`. The representations no longer send `private, no-store`.
- A PDF whose first page cannot be drawn is marked, so the thumbnail route answers 404 for a day without reading the original again.

Unit R3's first half landed after S1 and S2: `archive_replica` with its store, its reader, its machine, and its coordinator, and `scripted_archive`. It changed these points of the design.

- `archive_access` also holds `Timestamp`, `Clock`, `SystemClock`, and `ManualClock`, so both cores read one clock, and `ContentDigest`, `DocumentIdentifier`, `ArchiveAuthorization`, `PermissionLevel`, and `read_authorization`, which R2 had left in `collection_core` or unwritten. `collection_core` re-exports what it had. `ArchiveCredential` is still unwritten.
- `ArchiveCondition::RouteUnknown` exists. The exchange answers it for a 403 whose content type is not `application/problem+json`, and the collector counts it as a failed connection.
- `ArchiveExchange::get_within` takes the limit of one answer. The reader accepts 8,000,000 bytes of a page of changes, and a longer answer is a protocol violation.
- An extracted field of a type the client does not know is left out of its document, as an entry of an unknown kind is left out of its page. An unknown failure reason is kept as text, as an unknown status is.
- The schema is `replica_schema.sql` and not `migrations/0001_replica.sql`, because the copy has no migrations. The mirror row gains `credential_fingerprint`. A start reads the token from the credential store and follows the archive only with the token the copy was attached with, because another token may see another scope. With another token or none, the status still shows the mirrored archive, so `Disconnected` no longer means an empty store.
- `Filling` carries the remaining entries alone, and `Unreachable` carries the condition that caused it. `PageApplied` carries the store's `fill_complete` in place of an entry count, which tells a fill from a catch-up after a failure. The machine answers one optional effect, `RequestPage` or `AwaitDeadline`. It has no `DiscardCopy`, because the coordinator discards the copy before it reports `JournalReplaced`.
- Attendance is an argument of the machine, set by `Replica::set_attendance`. It takes effect with the next page, and a window that appears also wakes the replica.
- While the archive is unreachable, a wake caused by a person, by the application coming to the front, or by the system's wake retries at once. An accepted document does not, because the upload of a backlog reports one many times a minute and would undo the back-off. An outdated archive is asked at once only when a person asks.
- The coordinator requests a page on its own thread and applies it in the same step, as the usage above shows. It publishes the status where `Replica::status` reads it without the coordinator, so a status never waits for a request, while a command waits for the request in flight.
- `content_revision` rises only when a page changed a record. A document delivered again in the same state, as after a write to `indexed_at`, leaves it alone.
- A failure of the store is logged and ends the coordinator. The next start replaces a file it cannot open.
- A member's removal first gives its documents the assignment the archive gives a document without a member, because the schema checks `person_assignment` and the member together.
- After a 410 the mirror row keeps the former journal identifier, because the client reads nothing from a cursor. The next attachment then sees another identifier and empties the copy once more.
- `ReplicaStore::stage_page` writes a page without committing it. `apply_page` and the restart of the interleaving test are its callers.
- `scripted_archive` keeps records and a journal and answers `ArchiveReader`. `collection_core::scripted_archive` stays for the collector, because `collection_core`'s own unit tests use it, and a crate that `collection_core` depended on for tests would implement the trait of another build of `collection_core`. The crate answers no scripted failure yet.
- The interleaving test follows 60 seeds of 60 steps each, not 300 of 400, to finish in about a second. It fails at its first seed when `apply_page` stops comparing the cursor, when a removal is ignored, and when the scripted journal issues a number twice.

Unit R3's second half landed after the Worker's permission levels were reordered: the search tables, the listings with their difference, the facets, the document detail, the text lanes, and the cache. It changed these points of the design.

- `replica_store.rs` holds every statement that writes, and `replica_queries.rs` holds the reads of a window on read-only connections of their own, so two modules have SQL. `Replica` keeps the connections that no call uses and opens another when all are taken, so a search never waits for a listing. The modules `text_retrieval.rs` and `document_detail.rs` are new, and the detail and facet types live beside the listing, not in `lib.rs`.
- `extracted_texts` holds no digest. `write_document` removes the text row when the document's `original_sha256` changes, and `record_texts` keeps a text only while the document is archived with the content the text was requested for. So a document awaits its text exactly when it is archived and has no text row. A 404, and an answer the client cannot read, are stored as a row without Markdown, so one document never holds back the texts older than it.
- A lane reads up to 25 texts and reports once, and the coordinator writes a report in one transaction with one content revision. One revision per text would make every list read itself again some 20 times a second during a first fill. A text request that fails stops the lanes until the next page of changes is applied.
- `Replica::extracted_text` answers from the copy, and reads a text the lanes have not brought yet from the archive on the calling thread, then hands it to the coordinator to keep.
- Both search tables are contentless with `contentless_delete = 1`, and the text table has `prefix = '2 3'`. The search rows are written after the last record of a page, in the order of their rows, one row per statement, because FTS5 flushes at every savepoint. `AGENTS.md` has the trap.
- A document is found when every term is found in its details or in its text, each term by itself. It stands under `DetailsMatched` when the details hold every term, and under `TextMatched` otherwise, so "allianz kündigung" finds a letter whose sender is in the details and whose subject is in the text alone.
- A term shorter than three characters has no trigram. It is found at the beginning of a word of the text only, so "tk" finds the letters that mention the TK, under `TextMatched`. A term without a letter or a digit is left out, and a search text without a term lists what `Browse` lists by the document date, so the list does not empty while a person types a quotation mark.
- The detail row indexes a number with a full stop and with a comma (`72.09 72,09`) and a date as the archive writes it and as a letter prints it (`2026-10-06 06.10.2026`). The household is not indexed as a person, because the word would match most documents.
- Only the first 200 documents under `TextMatched` carry an excerpt, and a later one shows its summary. An excerpt reads a whole text, and a common word finds every text.
- A listing reads its rows without `ORDER BY` and sorts them in Rust, with the folding of the search for the alphabetical orders, so "Ärztliche Bescheinigung" stands under A. `documents.amount` and `documents.currency` repeat the two fields a row shows.
- `ListingOrder::Addition` has month headings by the day of arrival in UTC and no Arriving section. `Title` and `Sender` have no headings. `Browse` honours the order for every scope, `RecentlyAdded` included, so the window asks for `Addition` there.
- A `DocumentRow` holds the identifier, the condition, the title, the sender's name, the document date, the arrival, the amount, a passage that is the summary or the excerpt, and `content_known`, which says that a thumbnail can be asked for. It holds no category name, because a row shows none.
- `DocumentDetail` gives the person as `DocumentPerson`, `Household` or `Member` with a `NamedScope`, because the core has no word for the household. Its fields come in the order of the category's expected fields, then by key.
- `ReplicaStatus` gains `documents` and `documents_awaiting_text`. The counts of documents in ingestion and failed are in `ReplicaFacets`.
- A document whose `original_sha256` is null has no original to show (`NotAvailableYet`) and no thumbnail, and nothing is fetched for it. Only an email not yet printed and a document from before migration 0006 have no digest, and the archive answers the first with 409.
- Eviction never removes an original that was handed out within the last minute, and removes older ones whatever this run handed out. The time of the last handing out is the file's modification time, so a file that Quick Look still shows after a minute can lose its name while it stays readable. Originals are stored read-only. Thumbnails are not evicted.
- `RepresentationRefusal` has `NoLongerArchived` for a 404 and `NotConnected` for a copy that follows no archive because the start found no token for it. `Replica(ReplicaFault)` stands where the note has `Application`.
- `ArchiveExchange::download` writes a 200 answer to a destination as it arrives, with one second of timeout more for every 50,000 bytes of its limit. `ArchiveAddress::document_page` exists. `PermissionLevel` follows the server's new order, and the scripted archive's token has the level `read`.
- No committed test reaches `HttpArchiveReader`'s text, original, and thumbnail routes, `facets`, `document`, `thumbnail`, or `extracted_text`. Each ran once against a local server or the scripted archive on 2026-11-22. The end-to-end test of R4 is their first standing check.

Measured on 2026-11-22 with `cargo run --release -p archive_replica --example search_measurement` on the development server, x86_64 Linux with 8 cores at a load of 4 to 5 from other work, three runs of the program, each time the median of 9 runs of a query: 5,000 synthetic documents with 9.3 kB of text each, from 3,000 compounds with umlauts, 60 function words, amounts, dates, and numbers. perf is not permitted on that server, so each limit below comes from a run with the named part taken out.

| What | Time | What limits it |
| --- | --- | --- |
| A page of 250 documents, records and detail rows | 135 to 148 ms | The trigram rows: 42 ms without them. 211 ms when each row was written beside its record |
| The texts of 250 documents, 25 in a transaction | 283 to 330 ms | FTS5's tokenizer and prefix indexes: 56 ms without the text index |
| Every document by date, 5,000 rows | 17 to 19 ms | Reading the rows, 3.5 µs each. 55 ms with SQLite's sort and two joins into the fields |
| An IBAN, one document | 1.8 to 2.3 ms | The two FTS5 lookups |
| "talbrück kündigung", 1,382 documents | 20 to 23 ms | Reading the rows |
| "versicherung", 4,707 documents | 32 to 40 ms | Reading the rows, and 6 ms for 3,528 trigram matches |
| "geehrte" and "grüßen", every text | 26 to 35 ms | Reading 5,000 rows and 200 texts. An excerpt for every row would read each text, 18 µs, and walk it, up to 20 µs |
| The twelve keystrokes of "versicherung", each a new search | 383 to 427 ms together, 26 to 41 ms each | As above. The first two find every text |

The file took 21.7 MB with the records and the detail index and 93.8 MB with the texts and their index, of which the texts are 46.6 MB. The synthetic "versicherung" stands in most summaries, so a real archive answers it faster. A real archive also has more distinct words than 3,000 compounds, so its text index is larger.

Unit R4 (two commits: the united scripted archive + core hooks, then `application_bindings` and minimal Mac adaptation) landed with these points resolved:

- `ApplicationCore::connect_archive` checks `Collector::locked_archive_origin` (which reads the lock without raising the collector's revision) before hitting the network, so switching to an unreachable second archive answers `ArchiveDiffers { connected_host }` rather than `ArchiveUnreachable`. It returns `ConnectionGrant` (origin, host, token description, permission level, restricted flag, `reads`, `collects`) so a screen can explain read-only or ingest-only tokens cleanly.
- `ArchivePermission` gains `CollectOnly` alongside `ReadOnly` and `ReadAndCollect`, because an `ingest` token connects the collector alone while `LibraryStatus` still publishes the shared `ArchiveConnection`.
- `LibraryAnnouncements` derives `ArchiveConnection` from both `ReplicaStatus` and the collector's `(archive_origin, ConnectionStatus)`, wakes the replica with `WakeReason::DocumentAccepted` on `CollectorEvent::DocumentReceived`, refreshes the library only when the collector's connection snapshot changes (keeping 250 ms upload progress off the library's loop), and caches `Replica::facets()` counts per `content_revision`.
- `Amount` and `FieldValue::Number` cross UniFFI as `decimal_text: String` (normalizing `-0.0`) so Swift formats exact decimal values without floating-point drift.
- `Replica::stop(&self)` joins the coordinator thread behind a `Mutex`, allowing `ApplicationCore::shutdown` to stop the coordinator without waiting on unrelated representation downloads holding `Arc<Replica>`. At startup, crash repair connects an unconfigured collector offline only when the replica accepted its stored credential (`synchronization != Disconnected`).
- `scripted_archive` is united across both cores: `collection_core`'s coordinator unit tests moved to `collection_core/tests/coordinator_scenarios.rs`, `collection_core::scripted_archive` and its example server were removed, and `scripted_archive` implements both `ArchiveReader` and `ArchiveClient` over one store and journal alongside `scripted-archive-server` (all eight `/api/v1` routes plus `/scripted/held` and `/scripted/documents`).
- Verified on the Mac on 2026-11-22: `check_application.sh` passed all 101 Rust tests, SwiftFormat, SwiftLint `--strict`, XcodeGen, Release build, and `ApplicationEndToEndTests`; `cargo build --locked -p application_bindings --target aarch64-apple-ios-sim` succeeded; and a standalone Swift 6 program compiled with `-swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library` against `scripted-archive-server --seed 5000` filled 5,000 documents (5,001 rows) on `@MainActor`, measured 381.3 µs median across 25 calls to `listing.rows(first: 0, count: 64)`, downloaded a seeded 329-byte PDF original, and completed `shutdown()`.

## Open questions and risks

1. **Resolved in unit R4.** `ApplicationCore::connect_archive` compares `Collector::locked_archive_origin` before calling `GET /api/v1/authorization`, so an unreachable second archive answers `ArchiveDiffers` whenever the collector already holds folders or contents of another archive.
2. The collector core stores the token before its database commit, so a failed commit leaves the token in the Keychain. Should the store write come after the commit, or should a failed commit remove it?
3. The scripted archive cannot yet answer 409, 503, 415, or 405. `scripted_archive` must before the end-to-end test relies on those answers.
4. What made one run of the corpus following test on the Mac count differently?
5. **Resolved in unit R4.** `LibraryAnnouncements` holds the last observed `(archive_origin, ConnectionStatus)` from the collector alongside the replica's `ReplicaStatus`, re-derives `LibraryStatus` whenever either changes, and increments `LibraryStatus.revision` only when the published `LibraryStatus` differs from the previous one.
6. The reader's limit of 8,000,000 bytes for a page of changes is an estimate: 250 journal entries of about 2,000 bytes each. The first fill against staging measures real pages.
7. The copy requests every 5 seconds while it holds a document in ingestion. A document that stays there for good, such as an email that never prints, keeps every client at that interval. Should the interval grow with the document's age?
8. Should a 404 on a representation start a synchronization, so the removal arrives at once?
9. Is a delay of up to a minute acceptable for a document that arrives by mail while the window shows? If not, the changes route gains a `wait` parameter that holds the request until the archive's coordinator announces a change. The route's shape does not change.
10. Does the owner want failed documents on top of the list, as the browser has them? The design sorts them by date and lists them under Needs Attention.
11. Does the login launch of `SMAppService.mainApp` carry `keyAELaunchedAsLogInItem` on macOS 26? The application logs the launch origin at every launch, so one login at the screen settles it. If the marker is absent, the fallback is an `SMAppService.agent` whose property list passes `--started-at-login`.
12. When the Keychain refuses the token at start, the collector reports an unconfigured connection, so the application shows the connection form over existing folders. Should the core report this as its own condition?
13. Production D1 may differ from workerd's simulation. The triggers, `AUTOINCREMENT`, the cascade, and the batch were measured in workerd's local D1 on 2026-11-22. The migration's first run on staging is the real check, one `cf d1 migrations apply` before the deploy that reads the journal, and it needs the owner.
14. A migration that recreates a journaled table drops its triggers. The completeness test catches it, and the fix is to repeat the triggers in that migration. `AGENTS.md` gets one entry under "Things that will bite you".
15. A D1 Time Travel restore is assumed to restore `sqlite_sequence` with the data. The restore procedure in `notes/client_protocol.md` replaces the journal's identifier regardless.
16. The first thumbnail of each PDF is drawn by PDFium in the Worker on request. A person who scrolls a fresh archive of thousands causes that many renderings, a few at a time. R2 and the Mac keep them.
17. The search indexes were measured on synthetic text: 21.7 MB for the records and the trigram index of 5,000 documents, and 93.8 MB with the texts and their index, from a vocabulary of 3,000 compounds. Real text has more distinct words and trigrams. The first fill against staging measures it.
18. The end-to-end test ran in 10 seconds with a trivial application. With both cores, FSEvents, and the stabilization interval it takes longer. It should stay under a minute.
19. The application icon uses the classic icon set. macOS 26 draws its own material for an Icon Composer file, which only a graphical tool writes.
20. `apply_page` compares the cursor alone, and before a first page both cursors are absent. A page requested before the copy started over would therefore apply to the new fill. The coordinator cannot hold such a page, because it requests and applies in one step. A second writer of the file, such as a background task on the iPhone, would need a count of fills in the mirror row.
21. A token's scope cannot change today, so the copy trusts the scope digest it was attached with and never reads the authorization again. If Settings ever edits a token's scope, the replica must read the authorization when it follows.
22. Every token issued before the level order changed has the level `ingest` and cannot read, the staging ingest token included. The first fill against staging therefore needs a token of level `read`, which only the owner can issue in the staging archive's Settings.
23. A listing reads every row of its scope, 3.5 µs each, so an archive of 50,000 documents lists in about 180 ms and searches a common word in about 400 ms. Does the list then need rows read by window, or is 5,000 the size to build for?
24. During a first fill every report of a text lane raises the content revision, about twice a second, and each time a list reads itself again. Should a listing by date skip the read when only texts changed?
25. A text request that fails stops the text lanes until the next applied page, which is 15 minutes away while no window shows. Is that soon enough after a short loss of the network?
26. An excerpt opens at the first word that begins with any term, and "ß" is not folded to "ss", as in the search tables. Should the list mark the found words in the excerpt?

## Next implementation step

Units S1 (`70144d1`) and S2 (`39dcb64`, `34bb9e5`, `c348c9b`) are committed, so the Worker serves every route the native client reads. Units R1 (`5d78532`), R2 (`d7af1cd`), R3 (`1dd9b4e`, `f4feb6b`), and R4 (`81c20a5` and this commit) are committed too: the shared `archive_access` crate, `archive_replica` with search and cache, united `scripted_archive` with `scripted-archive-server`, `application_bindings` exposing `ApplicationCore`, `Library` (`DocumentListing` and `ListingDifference`), and optional `Collector`, and the adapted Mac interface scaffold. Build A1 next: rename the Mac gateway/situation/commands files to `ApplicationGateway` / `ApplicationSituation` / `ApplicationCommands`, add the plain window with the connection form and plain document table over `DocumentListing`, and extend `ApplicationEndToEndTests` up to "the corpus's documents are listed". Applying migrations 0008 and 0009 to staging and the deploy that serves the routes need the owner.

Units 1 and 2 of the first design are committed (`7ce2f82`, `94ca40c`), and so are D (`1f9ce3a`), R1 (`5d78532`), and R2 (this commit). Two streams run side by side because they touch disjoint trees: the Worker (`src/`, `drizzle/`, `test_fixtures/`) and the native client (`collector/`, then `native_client/`). Each unit ends in its check and one commit on `main`.

| Unit | Stream | What | Check |
| --- | --- | --- | --- |
| S1 | Worker | The journal: the two migrations, the schema's two tables and two lists, `change_journal.ts` with the page read and `scopeAdmission`, the completeness test, the paging test against the real writers (`reviseDocument`, `mergeTaxonomyRecords`, `deleteDocument`, the ingestion workflow's writes), the restricted-scope test | `pnpm check` |
| S2 | Worker | The client protocol: `collection_protocol` becomes `client_protocol` with the one route table and gate, the five new routes, the wire fixture `test_fixtures/client_protocol/changes_page.json`, the dispatch test extended | `pnpm check` |
| R1 | Client | The move: `collector/` to `native_client/`, the two bindings crates and the Swift targets to their `application_` names, the product to Schublade, the bundle identifier, with `AGENTS.md` paths, the workflow, the scripts, `.gitignore`. Names and paths only | The cargo checks on Linux and the Mac, `check_application.sh`, `pnpm check` |
| R2 | Client | `archive_access` extracted from `collection_core` | The cargo checks. The collector's scenarios pass unchanged |
| R3 | Client | `archive_replica` and `scripted_archive`: the store, the reader, the machine, the coordinator, the search, the cache; the interleaving test and the wire fixture test | The cargo checks on Linux and the Mac |
| R4 | Client | `application_bindings` widened: the root, the connection flow, `Library`, `DocumentListing` with its difference; `scripted_archive` serves all routes over HTTP | The cargo checks. The generated Swift compiles |
| A1 | Client | A plain window through every layer: the gateway over the root, the connection form, the documents in a plain table; the end-to-end test up to "the corpus's documents are listed" | `check_application.sh` over SSH |
| A2 | Client | The library's window: presentation, sidebar, list with pictures, reader, inspector, local search, status line, the renderer. The first shippable slice, in which Schublade reads | The rendered files in both appearances. The end-to-end test up to "an original is read" |
| A3 | Client | The collector's pages: the ported wording, the folder pages, the confirmation, Needs Attention, the notification | The presentation tests, the rendered files, the full end-to-end test |
| A4 | Client | The menu bar item: the glyphs, the animator, the menu | The presentation tests, the rendered glyphs |
| A5 | Client | The lifecycle: the activation policy, reopening, the main menu, Settings, the login item, the launch origin, the wake, the quit alert | The full end-to-end test |
| D | Both | The deletion of `collection_application` and `collection_interface`, with `AGENTS.md` and the workflow | `pnpm check`, the cargo checks |

Not done without the owner: applying a migration to staging, any deploy, and a session at the Mac's screen.
