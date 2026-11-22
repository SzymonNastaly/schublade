# iPhone application design

The design of Schublade for the iPhone, drafted on 2026-11-22. It extends `notes/native_client_design.md`, whose core, bindings, and archive routes it reuses, and it changes one premise of that design: the iPhone does not only read. The owner wants the iPhone application to replace a scanner application such as Quick Scan, so a person scans paper, shares files from other applications, and imports photographs into the archive from it, and reads the archive as the Mac does.

## Problem

Paper reaches a household on the kitchen table, not at the desk. Today a person scans it with a separate scanner application, saves a PDF, and uploads it through the browser or a collected folder. Every step between the photograph and the archive is a place where the paper waits. The iPhone application removes those steps: a person points the camera at a letter, taps once, and the letter is in the archive, classified within minutes, and readable on every device.

Three requirements follow.

1. **Capturing is faster than in a scanner application.** Scanning starts from the Home Screen, the Lock Screen, Control Center, the Action button, or Shortcuts, and a finished scan needs no naming, no folder, and no second confirmation.
2. **Nothing a person sent is lost.** A scan taken in a cellar without a network, or shared from Mail a moment before the phone locks, reaches the archive later without the person returning to it.
3. **Reading matches the Mac.** The list, the search, the reader, and the inspector work from the local copy and offline.

## Usage (a person's view)

| A person can                                         | How                                                                                                                 |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Scan a letter of several pages                       | The Scan button, which opens the system's document camera; Save sends the pages as one PDF                         |
| Start a scan without opening the application first   | The Home Screen quick action, the Control Center control, the Action button, and the Scan Document shortcut action |
| Send a PDF or a picture from another application     | Schublade in the share sheet of Mail, Files, Safari, Photos, and any application that shares files                 |
| Import from Photos or Files                          | The Add menu beside Scan                                                                                            |
| See what is on its way                               | The Sending section on top of the list: waiting, uploading, archived, or refused with the reason                   |
| Open what was just sent                              | The row of an archived submission opens its document once the copy holds it                                         |
| Browse, search, and read the archive                 | The list, the search field, the reader with the original, the text, and the details, as on the Mac                 |
| Take a document elsewhere                            | Share, Open In, and Quick Look                                                                                      |

Each of the following stays in the browser, as on the Mac: revising details, deleting, retrying a failed document, taxonomy maintenance, and tokens.

## Shape

### Submissions

A submission is one file a person chose to send: one scan as one PDF, one shared or imported PDF, or one picture. Several files shared at once become several submissions, because the archive makes one document of each file. A submission is never merged with another and never split.

Every submission goes through `POST /api/documents/ingest`, the route the browser's upload shares, and never through `PUT /api/v1/contents/{sha256}`. The collector's route refuses a content whose document the owner deleted, because a collector must never bring such a document back. A person who scans or shares a letter chose to send it, so the ingest route, which archives the bytes again, is the right one. The route needs a token of level `ingest` or above without a restricted scope. A token of level `read` permits both reading and sending, so the iPhone connects with one `read` token, as the Mac does. A restricted token reads its part of the archive, and the application then hides Scan, Add, and its share extension refuses with a sentence that says why. The extension cannot ask the archive while offline, so the application records whether the token is restricted, from `GET /api/v1/authorization` at connecting, beside the archive's address in the App Group's shared preferences.

The archive answers each file of a request with one of four outcomes: `accepted` and the new document's identifier, `already_archived` and the identifier of the document that holds the bytes, `rejected` with a reason, or `failed` with a reason when storing the file met an error and may succeed again (`UploadOutcome` in `src/ingestion/document_upload.ts`). An answer of 401 means the token was revoked, 403 that it no longer permits sending, 413 that the request was too large, and 5xx or no answer that the archive is unavailable. The application sends one file per request, so each answer belongs to exactly one submission.

### What a submission holds on disk

The queue lives in the App Group container that the application and its share extension share, because either may create a submission and either may receive its answer.

```text
<App Group container>/
	submissions/
		<submission identifier>/        one directory per submission, a random UUID
			submission.json               origin (scan, share, import), file name, media type, byte count, creation time
			document.pdf | document.jpg   the bytes as they are sent
			request_body                  the multipart body, written once, uploaded from the file
			answer.json                   written by the process that receives the answer
	incoming/                         directories under construction, renamed into submissions/ when complete
```

A writer builds a submission under `incoming/` and renames the finished directory into `submissions/`, so a reader never sees half a submission. The answer is the only file written after the rename, and it is written to a temporary name and renamed as well. No SQLite file is shared between the two processes: the replica's single writer stays the application's coordinator, which keeps open question 20 of the native client design from arising.

A submission whose answer is `accepted` or `already_archived` loses its `document.*` and `request_body` at once, because the archive holds the bytes, and its directory is removed when its document appears in the local copy or after seven days. A `rejected` submission keeps its bytes until the person removes its row, so Share can still take the file elsewhere.

### Uploading

Uploads run in a background `URLSession`, which the system continues while the application is suspended or terminated and retries when the network returns. Each task uploads `request_body` from its file with `uploadTask(with:fromFile:)`, and its `taskDescription` is the submission identifier. The application and the extension each own one session identifier, because two processes must not attach to one background session at once, and both sessions set `sharedContainerIdentifier` to the App Group, without which an extension's background upload cannot read its file. The extension starts the upload of what it created and ends. The system then launches the application in the background and calls `application(_:handleEventsForBackgroundURLSession:completionHandler:)` with the extension's session identifier; the application creates a session under that identifier, receives the remaining events, and calls the completion handler once they are delivered. The application also attaches to the extension's session at every launch, so an answer that arrives while it runs is not missed. Both delegates implement `URLSessionDataDelegate` and collect the answer's body, because an upload task's answer arrives as data and not as a file.

The background session retries a lost connection on its own. An answer of 5xx, an outcome of `failed`, or no answer is written to `answer.json` as unavailable, and the application starts the task again with a growing delay, at most once an hour, until it succeeds or the person removes the row. A 413 is final and counts as refused, because the same bytes would be refused again. A 401 or 403 holds every waiting submission and shows the connection as needing attention, exactly as the Mac's library does. On every launch and every return to the foreground, the application lists the tasks of both sessions and starts any submission that has neither an answer nor a task in either, which covers a crash between the rename and the task's start without sending an upload the extension still runs a second time. Only the process that writes a submission's `answer.json` removes its `request_body`.

### What Rust does and what Swift does

The wire format stays in Rust, as on the Mac: no wire type leaves Rust. A new module `document_submission.rs` in `archive_access`, which builds for the iPhone already, holds two pure functions.

```rust
/// Reads the token of `archive` from `credentials`, streams the multipart body of one file to
/// `destination` without holding the file in memory, and returns the request to send it: the
/// URL of the ingest route, the content type with its boundary, and the authorization header.
pub fn prepare_submission(
    archive: &ArchiveAddress,
    credentials: &CredentialStorage,
    document: &Path,
    file_name: &str,
    media_type: SubmissionMediaType,
    destination: &Path,
) -> Result<PreparedSubmission, SubmissionPreparationFailure>;

/// Reads the archive's answer to one file, whatever its status.
pub fn read_submission_answer(status: u16, body: &[u8]) -> SubmissionAnswer;

pub enum SubmissionAnswer {
    Archived { document: DocumentIdentifier, already_held: bool },
    Rejected { reason: String },  // the outcome rejected, or 413
    TokenRefused,                 // 401
    NotPermitted,                 // 403, a lower level or a restricted scope
    ArchiveUnavailable,           // the outcome failed, 5xx, or an answer that cannot be read
}
```

The bindings export both as free functions, so the share extension calls them without starting an `ApplicationCore`; the token is read from the Keychain inside Rust, as the Mac's core reads it. Swift moves the bytes, because only `URLSession` continues in the background, and `ureq` cannot. The authorization header therefore passes through Swift memory inside the prepared request. Swift never reads or stores it.

`SubmissionMediaType` is PDF or JPEG, PNG, and WebP, the kinds of `src/ingestion/source_file.ts`. Rust refuses a file above 25,000,000 bytes, the archive's `MAXIMUM_DOCUMENT_BYTES`, before anything is queued, so a person learns at once that a file is too large.

### Scanning

The Scan button presents `VNDocumentCameraViewController` from VisionKit, the system's document camera: it finds the page, corrects its perspective, captures automatically, offers color, grayscale, and black-and-white, and lets a person retake, crop, and delete pages before Save. Schublade adds no review screen of its own. Save creates the submission and closes the camera, and the Sending row confirms it. A scanner application that asks for a name and a folder after each scan is the step this design removes, because the archive names and files the document itself.

The pages become one PDF, each page a JPEG at quality 0.7 with its longer side at most 3,508 pixels, about 300 dots per inch on A4. A page then holds about 0.5 to 1 MB, so a scan of up to about 25 pages fits the archive's limit. The PDF is written page by page through Core Graphics, each page encoded with `CGImageDestination` inside its own `autoreleasepool` and placed as the JPEG it is, so a long scan never holds every decoded page at once. A scan above 25 MB is written again at a lower resolution and quality, down to 200 dots per inch and quality 0.5, before anything is refused. A scan that still does not fit is never discarded: it stays on the phone as a refused row with the sentence "This scan is larger than the archive accepts. Share it, or scan the letter in two parts.", and its Share hands the PDF elsewhere. The PDF carries no text layer: the archive reads its pages as it reads every scan.

### Sharing and importing

The share extension accepts PDF and image files, at most 20 per share, the archive's `MAXIMUM_FILES_PER_SUBMISSION`. It shows a compact sheet with the count of files and Send, creates one submission per file, starts their uploads, and closes. A HEIC or HEIF picture, which the archive refuses, becomes a JPEG at quality 0.85 first, through `CGImageSource` and `CGImageDestination` one file at a time, because a share extension is ended above about 120 MB of memory. A file of another kind is named in the sheet as one the archive does not take, and the others are sent.

The Add menu offers Photos through `PHPickerViewController`, which needs no permission to the library, and Files through `UIDocumentPickerViewController`, and both create submissions as the extension does.

### Starting a scan from outside the application

- The Home Screen quick action Scan Document.
- An App Intent, Scan Document, that opens the application with the camera presented. Shortcuts, Siri, and the Action button reach it.
- A Control Center control and a Lock Screen control, which run the same intent. They are a `ControlWidget` in a widget extension target, which exists only in SwiftUI and from iOS 18, so the application's deployment target is iOS 18 and the control extension is the one SwiftUI target. From the Lock Screen, the system asks for Face ID before the camera opens.

### Reading

The reading part follows the Mac's design with the iPhone's controls. It is written in UIKit, as the Mac's is in AppKit, so the iPhone shares the Mac's choice of the platform's own framework and VisionKit's camera, which is a UIKit view controller.

- The list is a `UICollectionView` with list layout over the same `DocumentListing`, with the Sending section on top and the month headings below. The sidebar's scopes become the filter menu of the navigation bar.
- Search uses `UISearchController` over the same local search.
- A document opens in a page with the original in `PDFView`, the Text and Details segments, and Share, Quick Look, and Open in Browser in its toolbar.
- On the iPad the same view controllers sit in a `UISplitViewController` with three columns; the iPad is not a goal of the first version, but nothing in it should prevent one.

The replica synchronizes while the application is in the foreground and in a `BGAppRefreshTask`. Both run in the application's process through its one coordinator, so the copy keeps a single writer. `Library::synchronize()` only asks for a synchronization, so the refresh task follows `Library::status_after` until the copy reports itself current or failed, then calls `setTaskCompleted`; its `expirationHandler`, which the system calls after about 30 seconds, completes the task as well and leaves the coordinator to continue at the next start. The originals' default limit is 500 MB, and Settings offers the Mac's Storage controls.

### Connecting

The connection form takes the archive's address and a token, as on the Mac. Typing a token of 43 characters on a phone is the step a person would get wrong, so the website's Settings shows a QR code beside a newly issued token, holding the archive's address and the token as a `schublade://connect` URL, and the connection form opens the camera to read it. The QR code is shown only while the token is, once, and is not stored.

### Credentials and the App Group

The token is one Keychain item in an access group that the application and the extension share, so the extension sends without asking. `CredentialStorage` gains an iPhone variant with the service name and the access group. The `keyring` crate's iOS store does not take an access group, so the variant writes the item through the `security-framework` crate directly, with the accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The default, readable only while the phone is unlocked, would fail a background refresh or an upload answer that arrives while the phone is locked. The archive's address is kept in the App Group's shared preferences, because the extension reads it too.

### The Swift code and the modules

```text
native_client/
	library_presentation/              Foundation only, shared by both applications: the library's wording, without the collector's
	iphone_application/                generated by XcodeGen, as the Mac's project is
		project.yml                      the targets below, the App Group, and the Keychain access group
		application_interface/           UIKit: the gateway, the controller, the list, the reader, Settings
		submission_queue/                Foundation only: the queue's directories, its states, and the session delegate; shared by the application and the extension
		share_extension/                 the share sheet's view controller
		control_extension/               the Control Center and Lock Screen controls
		application/                     main, the App Intent, and the quick action
		scripts/check_application.sh     the cargo checks, SwiftFormat, SwiftLint, the build for the simulator, and the tests
```

The native client design said that no Swift is shared with the iPhone application. This design shares the library's part of `ApplicationPresentation`, because its wording of dates, amounts, rows, details, and the library's status is Foundation only and exactly what the iPhone shows; a second copy would drift. That part moves into a new module, `LibraryPresentation`, which names no collector type and takes the device's wording, such as "on this Mac" or "on this iPhone" and the choices of the storage limit, as parameters. The collector's wording, the statuses that combine both cores, and the Mac's lifecycle and failure sentences ("Quit Schublade", "Application Support") stay in the Mac's `ApplicationPresentation`, which imports `LibraryPresentation`. Today 19 of its 44 files name a collector type. The Mac's interface, the iPhone's interface, and the bindings' gateway stay apart.

The static library for the iPhone is built for `aarch64-apple-ios` and `aarch64-apple-ios-sim`. `application_bindings` gains a cargo feature `collection`, on for the Mac and off for the iPhone, so the collector's crates, FSEvents, and its SQLite file are not linked into the phone. With the feature off, the generated Swift holds no collector type, which is why `LibraryPresentation` must name none.

## Tests

- Rust: `prepare_submission` writes a body that the Worker's multipart parser accepts, asserted against `scripted_archive`, which gains `POST /api/documents/ingest` with the Worker's four outcomes and its refusals; `read_submission_answer` reads each status.
- Swift Testing over `submission_queue`: a submission is created, answered, and removed; a directory under `incoming/` is never read; an answer without a task and a task without an answer are reconciled.
- One end-to-end test in the simulator against `scripted-archive-server`: connect, import a PDF from a file, see it in Sending, see it archived, and open its document from the list.
- What only a device can verify: the document camera, which the simulator does not offer; the share extension from Mail; a scan sent without a network that arrives later; the Control Center control; the background refresh. The owner's iPhone verifies these, and Peekaboo can watch the simulator for the rest.

## Alternatives considered

- **Upload through the collector's route.** `PUT /api/v1/contents/{sha256}` sends one file without multipart and checks the digest first, but it refuses a deleted content and answers 503 while the archive digests old documents. A person's choice to send must not depend on either.
- **Upload in Rust over `ureq`.** It keeps every request in Rust, but a suspended application stops its threads, and a scan taken just before the phone locks would wait until the application is opened again. Only a background `URLSession` continues.
- **The extension only queues and the application sends.** It keeps one session, but a file shared from Mail would not leave the phone until a person opens Schublade.
- **Read text on the phone.** Vision recognizes German text on the device for free, and a PDF with an invisible text layer would let the archive skip Moondream, which bills per page. It needs the text drawn at the right positions, and the archive's selection of text sources must keep preferring its own reading when the layer is poor. It is the first candidate for the version after this one.
- **SwiftUI.** It would let the iPhone and a future iPad share views with less code, but the Mac was built in AppKit by the owner's choice, VisionKit's camera and `PDFView` are UIKit anyway, and the patterns of the Mac's view controllers carry over to UIKit directly.
- **A review screen after scanning.** Quick Scan and others ask for a name and a folder. The archive classifies and names each document, so the review would only slow the step this design is for.

## Open questions and risks

1. Does the owner's Apple account belong to the paid Apple Developer Program? A free personal team cannot enable App Groups or a shared Keychain access group, and its installations expire after seven days. The share extension and the control therefore need the paid program, which makes it a prerequisite of unit I4. Without it, unit I3 keeps the queue in the application's own container and moves it into the App Group in I4.
2. Does the archive answer one large scan quickly enough over a mobile network? A 20 MB PDF on a slow uplink takes minutes; the background session carries it, but the Sending row should show the bytes sent.
3. Is 0.7 JPEG quality at 300 dots per inch readable enough for Moondream on small print? The test documents include photographed receipts, which can be scanned on the phone and compared.
4. Should a scan's pages be kept on the phone until the archive reports the document archived, not only accepted, so a document that fails ingestion can be sent again without scanning the paper again? The archive's Retry needs no new bytes, so this design keeps nothing.
5. Does the system deliver a background session's answer to the application when the extension that started it was ended, in every case on the current iOS? Apple documents it; the device test confirms it.
6. Should a scan show its own progress as a Live Activity on the Lock Screen while it uploads?

## Units

Each unit ends in its check and one commit on `main`. The order puts scanning before reading, because replacing the scanner application is what the owner asked for.

| Unit | What                                                                                                                                                                                                                                       | Check                                                                                       |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| I1   | The foundation: the iPhone Keychain variant, the bindings script for every platform, the static library for the device and the simulator, and an application shell whose end-to-end test copies the scripted archive on the simulator | The cargo checks, both `check_application.sh` scripts |
| I2   | Submissions in Rust: `document_submission.rs`, the bindings' two functions, `scripted_archive` serving the ingest route                                                                                                                    | The cargo checks on Linux and the Mac                                                       |
| I3   | The iPhone application's first slice: the project, the connection form, the submission queue with its background session, Scan, the Add menu, and the Sending list. Schublade replaces the scanner application from here on               | `check_application.sh` for the iPhone, the end-to-end import test, a scan on the owner's iPhone |
| I4   | The share extension, the App Intent, the quick action, and the Control Center and Lock Screen controls; needs the paid Apple Developer Program                                                                                                                                   | A share from Mail and a scan from Control Center on the owner's iPhone                       |
| I5   | Reading: `LibraryPresentation` split from the Mac's `ApplicationPresentation` with the device's wording as parameters, the list over the local copy, search, the reader, the details, the background refresh, Settings with Storage | The end-to-end test extended to opening a document; the rendered screens |
| I6   | The QR connection: the website's Settings shows the code beside a new token, the connection form reads it                                                                                                                                  | `pnpm check`, a connection by QR on the owner's iPhone                                      |

## Implementation reconciliation

Unit I1 landed with these points settled:

- The iPhone links `application_bindings` with the collector inside, for the device in Release and for the simulator in Debug, and starts it with `CollectionPlacement::Absent`. The `collection` cargo feature is therefore not needed to build, only to shrink the binary, and waits until its size matters. `LibraryPresentation` then needs to name no collector type for the build's sake, only for the wording's, and its split moved to I5, the first unit that shows the library.
- `CredentialStorage::SharedKeychain { service_name, access_group }` exists on iOS only. `SharedKeychainCredentialStore` removes an item and adds it again on every write, because `security-framework` updates by a query that would name the accessibility and miss an item written with another. The access group stays unset, so the item lives in the application's own group, until the share extension and a team exist (I4).
- `produce_application_bindings.sh` moved to `native_client/scripts/` and serves both projects, choosing the Rust target from Xcode's `PLATFORM_NAME`. It builds the generator without `SDKROOT` and `IPHONEOS_DEPLOYMENT_TARGET`, which Xcode sets for an iPhone build and which would link a Mac program against the iPhone's SDK.
- The bundle identifiers are `org.schublade.iphone` and `org.schublade.iphone.development`, and the deployment target is iOS 18. The simulator on the Mac runs iOS 26.5 under Xcode 27.2.
- The end-to-end test proves the Keychain by restarting the core after a document arrived: a second start that does not read the token stays at the old count, which a run with the token in process memory confirmed.

Unit I2 landed with these points settled:

- `prepare_submission` takes the token itself, and the bindings' `prepare_document_submission` reads it from the `CredentialStorage` the caller names, so the share extension passes its Keychain item and no token crosses into Swift but the header value. The multipart boundary is `schublade-` and the file's SHA-256, so the same file gives the same body and the boundary cannot occur inside it; a test asserts the body byte for byte.
- `read_submission_answer` maps 400, 405, 413, and 415 to `Rejected` with the archive's sentence, because the same body would be refused again, and every 5xx, the outcome `failed`, and an answer it cannot read to `ArchiveUnavailable`.
- The collector's `MAXIMUM_CONTENT_BYTES` is now `archive_access::MAXIMUM_DOCUMENT_BYTES`, so the two limits cannot drift.
- `scripted_archive` models a person's upload with `ScriptedArchive::upload`, which brings back a document the owner deleted where the collector's route answers 409, and `scripted-archive-server` serves `POST /api/documents/ingest` with a multipart reader of its own.
- The copy does not see a sent document until it next reads the archive's changes, every 15 minutes while no screen attends it. An `Archived` answer therefore calls `Library::synchronize()`, which the simulator test found when the document did not arrive within 30 seconds without it.

Unit I3 landed with these points settled:

- The queue lives in the application's own Application Support directory until I4 names an App Group, with one background session, `<bundle identifier>.submission-transfer`. Its module, `SubmissionQueue`, imports only Foundation and the bindings, so the share extension can link it unchanged.
- A body is prepared each time an upload starts, not when a submission is created, because the authorization header must be read from the Keychain at that moment anyway and the body file is removed with every answer. A submission that waits for the connection stays unanswered and starts when `followLibrary` first sees the archive's origin.
- An unavailable submission is sent again a minute after its first failure, doubling to at most an hour, and a removed row cancels its upload.
- A scan is named "Scan 2026-11-22 21.30.pdf", without the colon that Files shows as a slash. The scan writer's test draws three 12-megapixel pages and finds three A4 pages of the PDF under the limit; the document camera itself needs the owner's iPhone, because the simulator offers none.
- The iPhone's icon is the Mac's drawing with its plate filling the square, rendered by Quick Look on the Mac and flattened, because an icon with an alpha channel is refused. Xcode 27 fails the build of an iPhone application without one.
- Peekaboo cannot type into Device Hub, so the screens were examined through the Debug examination launch: three test documents archived and a text file refused, in both appearances.

Unit I4 landed with these points settled:

- Every shared name derives from the application's bundle identifier, which the Info.plists of the application and the share extension state as `SchubladeApplicationBundleIdentifier`, beside `SchubladeApplicationGroup` (`group.org.schublade.iphone`, or `.development` in Debug) and `SchubladeKeychainAccessGroup` (the team prefix and the bundle identifier). `SharedInstallation` reads them, and its container holds the queue under `submission_queue/` and the connected archive as `connected_archive.json`, written to a temporary file and renamed, in place of the shared preferences this design named. The application is the record's only writer and removes it while no archive is connected. The two sessions are `<application>.submission-transfer` and `<application>.share-extension.submission-transfer`. The controls extension holds neither group.
- Body preparation, both answer mappings, the HEIC conversion, and the share intake live in `SubmissionQueue`, so the application and the extension link one definition, and `SubmissionQueue.receive` records an answer in whichever process the session delivers it to.
- The activation rule accepts a share item of at most 20 attachments with a PDF or a picture among them. The share sheet on the simulator never offered an extension whose rule held `BETWEEN`, so the rule bounds with `<=`. The sheet ignores the address Safari shares beside a PDF, and a suggested name keeps only the extension of the kind sent.
- A scan requested by the intent, the control, or the quick action waits in `ScanRequestCenter` until the submissions screen shows, which opens the camera while the token may send and drops the request of a restricted token, whose screen says why it cannot send.
- On the simulator, driven with AXe against a scripted archive: a HEIC photo shared from Photos arrived as a JPEG and two PDFs from Safari as PDFs, and a photo shared again was answered as already archived. With the archive stopped and the extension's process killed after Send, the system launched the application in the background once the archive answered, and the application recorded the answer from the extension's session, which answers open question 5 for the simulator. The quick action opened the document camera from a cold start and from a running application. The App Shortcut is listed in Shortcuts but fails with "Couldn't find AppShortcutsProvider" after linkd cannot read a team from the ad hoc build.
- Both groups are enforced on the simulator: the access group of another application is refused with -34018, and another App Group's container is nil. The isolated environment therefore keeps its token in the shared access group and its container in a temporary directory.
- The owner's iPhone, signed with the team and the App Group, verifies what the simulator cannot: the Scan Document intent from Shortcuts, Siri, and the Action button, the Control Center and Lock Screen controls, a share from Mail, the share extension's memory under 120 MB with 20 photographs, a share sent without a network that arrives later, and a scan with the real camera.
