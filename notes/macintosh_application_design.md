# Macintosh application design

The design of Schublade Collector for macOS as a pure AppKit application over the Rust core, agreed before implementation on 2026-11-21. It replaces the Tauri application (`collector/collection_application`) and its React window (`collector/collection_interface`), which are deleted when the AppKit application matches them. The base came from one of two parallel candidates. [Synthesis decision](#synthesis-decision) lists what the other candidate contributed.

## Problem

The collector is a background utility. A person connects it once, adds a folder now and then, and otherwise meets it as one glyph in the menu bar. The Tauri application works, but it is a web page in a window. It has no dark mode, its login item shows as "exec" from an unidentified developer, and its menu bar item never changes.

The owner decided on pure AppKit with no SwiftUI, a core that stays in Rust so that an iPhone application can use it later, no Swift shared between the two applications, strict type checking, and few tests.

Three things make the shape non-obvious.

- Every call into the core blocks. `Collector::command` waits for the coordinator, the credential check waits for the network, and the start reads the Keychain, which can wait for a person to answer a prompt. None of it may run on the main thread.
- The status arrives two ways today. The core announces `StatusChanged { revision }`, and the window then reads the status. `status_following.ts` exists only to reconcile the two. Each application would write that again.
- The core's status is shaped for the coordinator. `backlog` is present exactly while a folder awaits its decision, `archive_origin` exactly while an archive is configured, and "being checked" is a sum of three of eleven counts. The React window derives each of these.

## Usage (caller's view)

On the development server, every Mac command runs through `scripts/execute_on_macintosh.sh`:

```bash
scripts/execute_on_macintosh.sh collector/macintosh_application/scripts/check_application.sh     # the one check
scripts/execute_on_macintosh.sh collector/macintosh_application/scripts/build_application.sh     # the application bundle
scripts/execute_on_macintosh.sh collector/macintosh_application/scripts/render_interface.sh      # every screen and glyph as PNG files
```

The application follows the collector with one loop on the main actor (`ApplicationController`):

```swift
private func followCollector() async {
	do {
		try await gateway.start(configuration: environment.collectorConfiguration)
	} catch {
		change(to: .failedToStart(error))                 // a CollectorStartFailure
		return
	}
	var revision: UInt64?
	while let status = try? await gateway.statusAfter(revision) {
		revision = status.revision
		change(to: .running(status))
	}
	change(to: .stopped)
}

private func render() {
	let context = WordingContext.current()
	window.render(windowContent(situation, settings: settings, context: context))
	statusItem.render(statusItemPresentation(situation, context: context))
}
```

A screen sends a command and words the refusal. It never reads the collector:

```swift
@objc private func uploadBacklog() {
	decision = Task {
		do {
			try await commands.decideBacklog(wording.folder.identifier)
			// The next status no longer has this folder awaiting a decision, so the sheet closes itself.
		} catch {
			refusalLabel.stringValue = decisionRefusalSentence(error, context: context)   // a DecisionRefusal
		}
	}
}
```

## Shape

### The boundary: `collection_bindings`

A new crate, `collector/collection_bindings`, exports the collector through UniFFI 0.32.2 with proc macros in library mode. `collection_core` gains no attribute and no dependency. `collector/collection_bindings_generator` holds `uniffi-bindgen-swift` at the same pinned version, so the `cli` feature stays out of the static library. Both crates build on Linux, and the core and a bridge compiled for `aarch64-apple-ios-sim` in the spike.

The exported functions are one start and one object:

```rust
pub async fn start_collector(configuration: CollectorConfiguration) -> Result<Arc<Collector>, CollectorStartFailure>;

impl Collector {
	pub async fn status_after(&self, revision: Option<u64>) -> Result<CollectorStatus, CollectorFault>;
	pub async fn connect_archive(&self, address: String, token: String) -> Result<(), ConnectionRefusal>;
	pub async fn enroll_folder(&self, root: String) -> Result<FolderReference, EnrollmentRefusal>;
	pub async fn withdraw_folder(&self, folder: FolderIdentifier) -> Result<(), WithdrawalRefusal>;
	pub async fn decide_backlog(&self, folder: FolderIdentifier) -> Result<(), DecisionRefusal>;
	pub fn system_resumed(&self);
	pub async fn shutdown(&self);
}
```

The crate hides four things behind those eight functions.

- **Following by revision.** `status_after(revision)` answers the first status whose revision exceeds the argument, or the current status for `None`. It waits on an `event_listener` that one thread raises for each `StatusChanged`. The listener is registered before each read, so no announcement falls between a read and the wait. A caller that passes back each answer's revision never sees an older status after a newer one. No foreign trait exists, so no Rust thread calls into Swift. `DocumentReceived` stays inside the crate, because the receipts in the status carry the same fact.
- **Blocking.** Every `async` function wraps its core call in `blocking::unblock`. The thread that polls the future, which can be the main thread, never waits on the coordinator, the network, or the Keychain. Swift needs no queue and no actor for this.
- **Composition.** The second start after an unreadable database, the credential check before a connection is stored (`HttpArchiveClient::verify_credential`), and the mapping of start failures move here from `collection_application`.
- **Derivation.** `published_status.rs` defines the status as an application shows it, and `publish` is the one conversion from the core's status. It destructures every core struct without `..` and matches every core enum without a wildcard arm, so a new field or variant in the core fails to compile here until someone decides what an application shows for it.

The published types remove the states the React window guarded at run time:

- `ArchiveConnection` is `NotConfigured` or `Configured { origin, host, condition }`.
- `FolderAdmission` is `Surveying { files_under_examination }`, `AwaitingDecision { backlog }`, or `Collecting`.
- `FolderStatus.unavailability` is `Option<FolderUnavailability>`, and `FolderUnavailability` has no available case.
- `BacklogSummary.skipped` is one list over one `SkipReason`, with no zero counts.
- `CollectionProgress` holds the three counts a person reads.
- `AttentionItem` has one `BacklogAwaitsDecision` per folder and no `ArchiveNotConfigured`, which `ArchiveConnection` says.
- `Receipt.outcome` is `Processing`, `Archived`, or `Failed`.

`FolderIdentifier` is a record with one field, so Swift gets a distinct type and cannot pass a revision as a folder. `FolderReference` is the identifier with the folder's root. The name a person reads comes from `FileManager.displayName(atPath:)` on the Swift side, because Finder shows localized names such as "Dokumente". Times cross as `SystemTime` and arrive as `Date`.

Refusals are one error enum per command: `ConnectionRefusal`, `EnrollmentRefusal`, `WithdrawalRefusal`, and `DecisionRefusal`, each with `Collector { fault: CollectorFault }` for what any command can answer. A refusal that names a folder carries its `FolderReference`. Each Swift wording function is then one total `switch` with no default sentence.

`CredentialStorage` is `Keychain { service_name }`, compiled only for macOS, or `ProcessMemory`. The Keychain stays with the core's `KeychainCredentialStore` under the bundle identifier, so the item the Tauri application stored keeps working.

### The Swift modules

The generated Swift fails to compile in a module whose default isolation is `MainActor`, so it gets its own module. Presentation is a module that imports Foundation only, so no view logic can reach it.

| Target | Directory | Holds |
| --- | --- | --- |
| `CollectionBindings` | `generated_bindings/` | The generated Swift, with nonisolated default isolation. Git ignores it. |
| `CollectorPresentation` | `collector_presentation/` | Pure functions from a `CollectorSituation` to `Equatable` values: the wording, `windowContent`, `statusItemPresentation`, and `windowOpensAtLaunch`. |
| `CollectorInterface` | `collector_interface/` | The AppKit application: the gateway, the controller, the window, the screens, the status item, and the controls. |
| `SchubladeCollector` | `application/` | `main.swift`, the asset catalog, and the generated `Info.plist`. |
| `CollectorPresentationTests` | `collector_presentation_tests/` | Swift Testing, with no host application. |
| `ApplicationEndToEndTests` | `application_end_to_end_tests/` | One XCTest bundle that Xcode loads into the real application. |
| `InterfaceRenderer` | `interface_renderer/` | A command-line tool that writes every screen and glyph to PNG files. |

Directories use lower case with underscores, as everywhere in the repository. A Swift file bears the name of the type it declares.

Every piece of state has one writer.

| State | Owner | Kept in |
| --- | --- | --- |
| The started collector | `CollectorGateway`, the only type that imports `CollectionBindings` for calls | Memory |
| The situation: starting, failed to start, running with the latest status, or stopped | `ApplicationController` | Memory |
| Whether the menu bar item shows | AppKit, through `NSStatusItem.isVisible` under an `autosaveName` | User defaults, written by AppKit |
| Whether start at login was ever established | `ApplicationPreferences` | User defaults |
| Start at login | The system, through `SMAppService.mainApp` | Read on each activation |
| The ingest token | The core's Keychain store | The login Keychain |
| The activation policy and the window | `CollectorWindowController` | AppKit |
| A form's text and the attempt in flight | That form's view controller | Its fields |
| The animation's frame and timer | `StatusItemAnimator` | Memory |

Data moves one way. `ApplicationController` stores the one `CollectorSituation` and calls two pure functions. Each controller has a `render` that takes its value and skips work when the value is unchanged. A screen holds a `CollectorCommands` value, a protocol of four `async` functions with typed throws, and nothing else of the application. The wording of `status_sentences.ts`, `backlog_confirmation_wording.ts`, `number_wording.ts`, and `time_wording.ts` carries over sentence for sentence. The clock, the locale, and the folder names enter through a `WordingContext`, so tests and the renderer fix them.

### How a person meets the application

The menu bar item opens a real `NSMenu`: the connection sentence, what is in flight, the counts, what needs attention, the five newest uploads, Open Schublade Collector, Settings, and Quit. A menu is keyboard-navigable and read by VoiceOver without extra work.

One window holds the rest. The first implementation uses toolbar tabs for Status, Folders, and Settings, with the confirmation of one folder as a sheet. The owner has a second layout to choose from, a sidebar with one entry per folder and a separate Settings window. The layout lives only in `collector_interface/window/` and `collector_interface/screens/`, so the choice changes nothing below them.

The confirmation has two groups, "The files already there" and "From now on". The second group always reads that every new PDF, JPEG, PNG, or WebP file in the folder uploads automatically and that the application does not ask again for this folder.

The menu bar item has six glyphs, drawn in code as template images from the drawer's geometry, in this order of precedence:

1. `attentionRequired`: the start failed, the token is suspended, a folder awaits its decision, or a folder cannot be read.
2. `archiveNotConnected`.
3. `archiveUnreachable`: unreachable, deferred, or checking.
4. `submitting`: an upload is in flight. Eight frames show a sheet that sinks into the drawer.
5. `resting`.
6. `starting`, before the first status.

A timer in the common run loop modes swaps the frames, and it exists only while an upload is in flight. The animator finishes the cycle it began, so a short upload shows one whole motion. Reduce Motion shows one still frame. Core Animation is not used, because layer contents bypass the template tint.

Schublade keeps the drawer, its blue as the accent colour, and every sentence. Fonts, controls, spacing, and the badge colours are the system's.

### Lifecycle

- `LSUIElement` starts the application with the Accessory policy, so a start at login shows no Dock icon. `CollectorWindowController` sets Regular when the window opens and Accessory when it closes.
- `LSMultipleInstancesProhibited` makes a second open arrive at the running application as a reopen, which shows the window. A process started outside Launch Services finds the first one with `NSRunningApplication` and ends. The core's database lock stays the last guard.
- `SMAppService.mainApp` registers the login item on the first configured status, once. Afterwards the person decides.
- The launch origin comes from the launch Apple event in `applicationDidFinishLaunching`: an open-application event whose `keyAEPropData` is `keyAELaunchedAsLogInItem`. A login launch keeps the window closed only while the collector runs and an archive is configured. A failed start or a missing archive opens the window even at login.
- `NSWorkspace.didWakeNotification` calls `system_resumed`.
- Terminating answers `.terminateLater`, awaits `shutdown()`, and replies.
- The bundle identifier stays `org.schublade.collector`, with `org.schublade.collector.development` for Debug. The data directory `~/Library/Application Support/<identifier>` and the Keychain service stay too.

### The build

XcodeGen writes `SchubladeCollector.xcodeproj` from `collector/macintosh_application/project.yml` on every script run, and git ignores the project. The `CollectionBindings` target has a pre-build phase that runs `scripts/produce_collector_bindings.sh`:

1. `cargo build -p collection_bindings --target aarch64-apple-darwin` with `MACOSX_DEPLOYMENT_TARGET` equal to the Swift deployment target.
2. `uniffi-bindgen-swift` on that exact library.
3. Replacement of each generated file only when it changed.

The bindings are never committed. Generated Swift that differs from the linked library ends the application at launch with a checksum mismatch, and generation takes 0.2 seconds. Every executable links the Rust library with Security, CoreFoundation, CoreServices, and iconv.

Every target uses the Swift 6 language mode, complete strict concurrency, and warnings as errors. SwiftLint in strict mode and SwiftFormat in lint mode run in the check. Custom SwiftLint rules refuse `import SwiftUI`, AppKit inside `collector_presentation/`, a call of the bindings outside `CollectorGateway`, `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency import`, `DispatchQueue.main`, and Interface Builder files.

The build is arm64 only, with macOS 14 as the deployment target. Only macOS 26 has been tested. Signing is ad hoc. `configuration/signing.xcconfig` includes an optional, ignored local file for the Developer ID identity and the team.

`scripts/check_application.sh` runs the cargo checks, SwiftFormat, SwiftLint, the build of every target, the presentation tests, and the end-to-end test.

### Tests

The compiler carries most of the weight: exhaustive switches over generated enums, typed throws, `publish` without wildcards, and main-actor isolation. Tests cover what the compiler cannot.

| Test | Where | Protects |
| --- | --- | --- |
| A read for the current revision waits for the next commit, and the first read answers at once | `collection_bindings` | The loop every screen rests on |
| Following a survey of the corpus never goes back and reaches the last status | `collection_bindings` | Following by revision |
| Shutdown ends every read | `collection_bindings` | Termination |
| Every refusal of the core reaches the command that caused it | `collection_bindings` | The refusal mapping |
| A status is published with one list of skipped entries | `collection_bindings` | `publish` |
| The confirmation's sentences, counts, and grouping | `CollectorPresentationTests` | The consent a person gives |
| "Everything is collected" only when true, and the attention, refusal, and time sentences | `CollectorPresentationTests` | What the application claims |
| The glyph's precedence, the end of the animation, and Reduce Motion | `CollectorPresentationTests` | The menu bar item |
| Which screen shows, and which launch opens the window | `CollectorPresentationTests` | A collector that never stops unseen |
| A folder is enrolled, confirmed, collected, and followed | `ApplicationEndToEndTests` | Everything together |

No test builds a view except the last, and none compares a picture.

The end-to-end test runs over SSH. `xcodebuild test` starts the Debug application and loads the test bundle into it. The environment selects an isolated `ApplicationEnvironment`: a temporary data directory, the token in process memory, preferences in a throwaway suite, and an inert login item. This switch exists only in Debug builds. The test presses controls through `InterfaceIdentifier`, passes a copy of `test_fixtures/collection_corpus/Downloads` in place of the folder panel, and talks to `collection_core/examples/scripted_archive_server.rs`, which puts the core's `ScriptedArchive` behind the three HTTP routes. The real bundle, the gateway, the bindings, the core, FSEvents, and the HTTP client all run.

`InterfaceRenderer` builds the real view controllers from fixed situations and writes each screen, the confirmation, the menu's rows as text, and every glyph and frame, in both appearances. It renders a whole window through its frame view with `cacheDisplay(in:to:)`. A person or an agent looks at the files. Nothing compares them.

Only a session at the Mac's screen can verify the following:

1. The glyph in the real menu bar, light and dark, its animation during an upload and during an open menu, and Reduce Motion.
2. The menu opening on a click and its rows updating while open.
3. The Dock icon and the main menu appearing with the window and leaving with it.
4. The window in its key look: default buttons, the focus ring, the tab order, and VoiceOver.
5. The folder panel and the privacy prompts for Downloads, Desktop, Documents, and a cloud folder.
6. Start at login: the entry under Open at Login with the name and the icon, a logout and login with no window, and the logged launch origin.
7. The Keychain prompt for the existing item, and the same after a rebuild.
8. A second copy of the application.

## Synthesis decision

Candidate 1 is the base. A judge on another model scored it 25 to 22 and named the same base. Its published types put each derivation in Rust once for both applications, its presentation module cannot import AppKit, its screens were rendered in both appearances, and its end-to-end check is a stock `xcodebuild test` that exercises the real HTTP client.

From candidate 2:

- The long read `status_after(revision)` with `async` functions over `blocking::unblock` replaces candidate 1's `StatusObserver` foreign trait, its lock held across a Swift callback, and its actor on a dispatch queue. Probed: a main-actor loop received each revision once and in order while a 50 ms main-thread timer fired 19 times in 0.97 s.
- Xcode targets with a pre-build phase replace candidate 1's Swift package with an XCFramework. Probed as a whole: 15.6 s from nothing and 1.4 s with no change. One build tool builds everything, and Xcode alone can build the project.
- `NSStatusItem.autosaveName` with `isVisible` as the one record of the menu bar item's visibility.
- `LSMultipleInstancesProhibited` with the hand-over to the running application.
- Folder names from `FileManager.displayName(atPath:)`.
- A login launch also opens the window when no archive is configured.
- Directories in lower case with underscores.

Rejected from candidate 2: `#[uniffi::remote]` mirrors of the core's status with three changes to the core. They need no conversion code, but Swift would still derive what a screen shows, once per application, and the changes alter what `schublade-collector status --json` prints. Also rejected: a synchronous start on the main thread, which waits behind a Keychain prompt, and a driver compiled into the Debug application in place of a hosted test.

## Tradeoffs accepted

- We accept about 250 lines of conversion in `publish` in exchange for published types that hold no rule a Swift caller must remember.
- We accept two small crates, `blocking` and `event-listener`, in exchange for an application with no callback from a Rust thread and no revision rules of its own.
- We accept that UniFFI maps no Swift cancellation to Rust, so a waiting `status_after` ends only with a newer status or with `shutdown`.
- We accept that a debug static library is about 150 MB and that every executable links it, in exchange for bindings generated from the exact library on every build.
- We accept Keychain prompts after each ad hoc rebuild until a stable signing identity exists, in exchange for one credential store shared with the command-line program.
- We accept a Debug-only environment switch in the application in exchange for an end-to-end check of the real bundle that never touches the Keychain.
- We accept that the Tauri application's two stored preferences are not carried over.
- We accept that the window decision at a login launch rests on an Apple event property not yet observed under `SMAppService`. A wrong answer opens the window and never hides a failure.

## Alternatives considered

- **An exported `status()` and an event callback, with the following in Swift.** This is today's shape. It puts a revision comparison, a reread loop, and an ordering rule into each application.
- **Swift owns the Keychain.** It duplicates the core's credential store for each platform and makes the token cross the boundary on every start.
- **A popover from the menu bar item.** It is custom chrome for content a menu already holds, and it is awkward for the keyboard and VoiceOver.
- **SwiftPM alone, or a hand-kept project.** SwiftPM produces no bundle, no `Info.plist`, and no signature. A hand-kept project file cannot be reviewed as text.
- **A universal build.** The owner's Macs are Apple silicon. Release can gain an x86_64 slice later in `produce_collector_bindings.sh`.

## Implementation reconciliation

## Open questions and risks

1. Does the login launch of `SMAppService.mainApp` carry `keyAELaunchedAsLogInItem` on macOS 26? The application logs the launch origin at every launch, so one login at the Mac's screen settles it. If the marker is absent, the fallback is an `SMAppService.agent` whose property list passes `--started-at-login`.
2. Which window layout does the owner choose, tabs or a sidebar?
3. Should a finished survey post a notification? It needs the notification permission prompt. The design shows the attention glyph and nothing else.
4. When the Keychain refuses the token at start, the core reports an unconfigured connection, so the application shows "Connect your archive" over existing folders. Should the core report this as its own condition?
5. Risk: a `cfg`-guarded variant of an exported enum type-checks on macOS. Nobody has compiled the crate on Linux, where the Keychain variant is absent. Unit 1 meets this on its first build.
6. Risk: the end-to-end test ran in 10 seconds with a trivial application. With the core, FSEvents, and the stabilization interval it takes longer. It should stay under a minute.
7. Risk: the application icon uses the classic icon set. macOS 26 draws its own material for an Icon Composer file, which only a graphical tool writes.

## Next implementation step

Write `collection_bindings/src/published_status.rs` with `publish` and its test, then `status_following.rs` with its tests against the scripted archive. Every later unit consumes the published status.

The units, each ending in its check and one commit:

1. `collection_bindings`, its generator, and `scripted_archive_server`. Check: the three cargo commands on Linux and on the Mac.
2. The build with almost no interface: `project.yml`, the scripts, `CollectorGateway`, an application that starts the collector and shows a plain menu bar item, and the end-to-end test up to the first status. Check: `check_application.sh` over SSH.
3. `CollectorPresentation` with the ported wording and its tests.
4. The renderer, the controls, and the screens. Check: the rendered files, looked at in both appearances.
5. The menu bar item: the drawing, the animator, and the menu.
6. The lifecycle: the window controller, the activation policy, the reopen, the main menu, the preferences, the login item, the launch origin, and the wake. Check: the full end-to-end test.
7. The deletion of `collection_application` and `collection_interface`, with `AGENTS.md` and `.github/workflows/collector.yml`.
8. A session at the Mac's screen for the list above.
