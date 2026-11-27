# Schublade for iPhone: design direction

Written on 2026-11-23 against commit `e148108`. It is a direction for implementers, not code.

## The goal

The owner wants the iPhone application to comply with the Human Interface Guidelines, to be understood without instructions, and to feel like the native applications of small studios: Overcast, Bear, Crouton. The application has one loop, in this order of importance.

1. A person points the camera at a letter, taps once, and the letter goes to the archive.
2. The person sees it on its way and then archived under its real title.
3. Later the person finds and reads any document offline.

Editing, deleting, retrying, and tokens stay in the browser.

## What this direction rests on

- I looked at 26 simulator screenshots of the build at `e148108`: the library, search, the scope menu, the document page, the share sheet, the connection form, the document camera, and the quick actions. They were taken in a working session and are not kept in the repository.
- I read every Swift file of `application_interface/`, `share_extension/`, `control_extension/`, the icon drawing, `library_presentation/`, `notes/iphone_application_design.md`, and the exported types of `application_bindings`.
- Every iOS 26 API named here exists in the SDK on the Mac. I checked the names in the UIKit, PDFKit, and VisionKit headers of `iPhoneSimulator27.2.sdk` over `ssh mac`.
- Every SF Symbol named here exists in the Mac's `CoreGlyphs.bundle`, and each was released in 2024 or earlier, so iOS 18 has it.
- The Mac has one simulator runtime, iOS 26.5. No screenshot can prove the iOS 18 fallback until an iOS 18 runtime is installed there.
- The contrast ratios are computed with the WCAG formula from the hex values in `InterfacePalette.swift` and the `AccentColor` asset.
- Comparisons with Apple's applications and with Overcast, Bear, and Crouton are from memory. I did not open them in this session.

## The five decisions

1. **One screen, no tabs.** The library is the root. What is on its way sits at its top. Settings is a sheet. Scan is the one prominent button, at the bottom right, beside the search field.
2. **A sent letter is one row from Save to its real title.** The row shows the scanned page at once, a progress ring, the archive's reading stage, and then becomes the document. It leaves the top when the person leaves the application.
3. **The original is the hero of the document page, and the details are a sheet over it.** The sheet opens at half height by default and remembers whether the person closed it, as the Mac's inspector does. The segmented control, the Quick Look button, and the browser button leave the page.
4. **The title of the list names what the list shows.** "All Documents", "Receipt", "Mühlbach Bank AG". The word "Schublade" leaves the navigation bar.
5. **No camera on a plain launch.** The application opens on the library. The quick action, the control, the Action button, and the shortcut open the camera before the core has started.

---

## 1. Critique of the current build

### The library (`final_list_light.png`, `list_dark.png`, `scoped_list_light.png`)

- The largest text on the screen is the application's name, on every launch, in every scope. What the list shows is a small grey subtitle under it. In `scoped_list_light.png` only the word "Receipt" in that subtitle says that ten documents are hidden.
- Each row says the same three facts three times. "Frischemarkt Talbrück Receipt October 2026", then "Frischemarkt Talbrück GmbH · 31 Oct 2026", then "Receipt from Frischemarkt Talbrück GmbH over 29,63." A row is about 110 points tall, so five and a half rows fit.
- The amount shares the title's first line, so the title wraps at about 60 % of the width. "Zahnarztpraxis Vossberg Dental Invoice Lena Becke…" truncates while a third of the row is empty.
- The amount in the row is "29.63 EUR" and the summary beside it says "29,63". Two number formats sit one line apart.
- The Sending row shows a file name a machine wrote ("Scan 2026-11-23 09.12.pdf"), a bare time, and a generic blue page icon where every document row shows its page. It is the confirmation of the application's main action, and it is the least designed row on the screen.
- "Already in the archive" stays for seven days (`SubmissionQueue.archivedRetention`). After a week of scanning, the top of the list is a log.
- The filter button is a circle drawn inside a glass circle. The same doubled circle appears on the document page's buttons.
- The floating "+" at the bottom left covers the thumbnail of the last visible row.
- The stage text and the failure text of a row use `InterfacePalette.archive` and `InterfacePalette.attention` as text colours. On white they measure 3.08:1 and 2.73:1, below the 4.5:1 that body text needs.
- Nothing on the screen says whether the copy is current or offline. The Mac has a status line. The iPhone uses `StatusLinePresentation` only while the first copy fills.
- A token that the archive refused leaves the person on this screen with a row that says "Connect again to send" and no way to connect again. `RootViewController` shows the connection form only while no archive is configured.

### The empty archive (`empty_archive_light.png`)

- The words are right. The screen offers Scan twice, shows a filter that has nothing to filter, and uses the generic `tray` symbol where the application's own drawer belongs.

### Search (`search_light.png`, `search_text_light.png`)

- The chosen scope disappears while a person searches, so a search inside "Receipt" looks like a search of everything.
- The excerpt does not mark the words that matched, so "Matches in Text" rows read like any other row.
- The dates "Due on 2026-10-20" in the passages are ISO dates beside "5 Oct 2026" in the line above. The archive writes the summary, so the application cannot fix the sentence. It can stop showing the summary where it adds nothing.

### The document page (`final_sending_opens_light.png`, `final_reader_details_light.png`, `final_reader_text_light.png`)

- The title appears three times: truncated in the navigation bar, in a card on top of Details, and as the heading of Text. None of the three shows the whole title beside the page.
- The subtitle in the bar truncates at "· 1 p…".
- The segmented control takes a row of about 48 points and hides the amount, the due date, and the IBAN, which are what a person opens an invoice for, behind a mode switch.
- The toolbar is three lone glass circles: Share, an eye, and a compass. The eye opens Quick Look, which shows the same PDF as the Original segment under it. The compass opens the browser and nothing says why a person would go there.
- The buttons float over the content. In `final_reader_details_light.png` the IBAN's neighbour row is unreadable under them.
- In Details, the values are grey and the labels are black. The values are the content. Three values are link-blue with a chevron, the others are grey, and every value copies only through a touch-and-hold that nothing announces.
- The page sits in a blue-grey band with about 75 points of empty backdrop above it, between two opaque bars. Nothing extends under the glass.

### The share sheet (`sheet.png`)

- A full-height dark sheet holds one sentence, "Send 1 document to 127.0.0.1:54426." It shows no picture of what is being sent.
- A host and a port are how a program names an archive.
- The Send button draws cyan text on system blue. The extension does not carry the application's accent colour.
- After Send the sheet closes without any sign that the file is on its way.

### The connection form (`form.png`)

- It is the first screen a person ever sees, and it is a login form: a title "Connect", a grey paragraph, two bordered text fields, a button. It shows no icon and does not say what Schublade does.
- A person must type or paste a 43-character token. The QR connection of unit I6 is not built.
- The fields are in a fixed stack with no scroll view, so the keyboard can cover the button on a small phone.

### Scan (`camera.png`, `DocumentCapture.swift`)

- The system's document camera is the right choice and needs no change.
- After Save the camera slides away and nothing happens until the PDF is written. Then a text-only row appears. No haptic marks the moment.
- A scan request from Control Center on a restricted token is dropped without a word (`LibraryViewController.answerScanRequest`).

### Settings

- No Settings screen exists. `notes/iphone_application_design.md` lists "Settings with Storage" under unit I5, but no file of `application_interface/` calls `originalStorage`, `setOriginalStorageLimit`, or `removeDownloadedOriginals`.

---

## 2. Information architecture

### One navigation stack

```text
RootViewController
├─ starting: a blank screen in systemBackground, no spinner for the first 400 ms
├─ ConnectionFormViewController   (no archive configured)
└─ UINavigationController
   └─ LibraryViewController       (root)
      ├─ push  DocumentPageViewController
      │        └─ sheet  DocumentDetailsViewController  (medium and large detents)
      ├─ sheet SettingsViewController in its own UINavigationController
      │        └─ push  ConnectionFormViewController in its replace-token form
      ├─ full screen  VNDocumentCameraViewController
      └─ sheet PHPickerViewController, UIDocumentPickerViewController
```

Tabs would give "Sending" and "Settings" the same weight as the library. Sending is empty most of the day and Settings is opened a few times a year. A tab bar is for peers, and Scan is an action, which a tab bar must not hold. So the application keeps one stack.

### The library's bars

iOS 26:

```text
┌──────────────────────────────────────────┐
│                                    ( ⋯ ) │  navigation bar
│ All Documents                            │  large title
│ 128 documents                            │  large subtitle
│                                          │
│ ARRIVING                                 │
│ ▢ Scan                              ◔    │
│   3 pages · 09:12                        │
│   Sending                                │
│ October 2026                             │
│ ▢ Mühlbach Bank Account Statement Oct…   │
│   Mühlbach Bank AG · 31 Oct              │
│ ▢ Frischemarkt Talbrück Receipt Octob…   │
│   Frischemarkt Talbrück GmbH · 31 Oct    │
│                               29.63 EUR  │
│ …                                        │
│ ( ≡ )  (  🔍 Search            )  ( ▣ )  │  toolbar
└──────────────────────────────────────────┘
```

- **Navigation bar, trailing.** One `UIBarButtonItem(title: "More", image: UIImage(systemName: "ellipsis"), menu:)`. Its menu holds "Choose Photos" (`photo.on.rectangle`) and "Choose Files" (`folder`) in one inline section and "Settings" (`gearshape`) in a second. The first section is absent while the token may not send.
- **Toolbar.** `toolbarItems = [filterItem, navigationItem.searchBarPlacementBarButtonItem, scanItem]`, with `navigationItem.preferredSearchBarPlacement = .integrated`. This is where iOS 26 puts search and the main action in Mail and Notes.
  - `filterItem`: `line.3.horizontal.decrease`, title "Show", the scope menu. `isSelected = true` while a scope other than All Documents is chosen. The `.circle` variants go, because the glass already draws the circle.
  - `scanItem`: `doc.viewfinder`, title "Scan", `style = .prominent`, tinted by the window's tint. Its primary action opens the camera. Its `menu` holds "Choose Photos" and "Choose Files", which UIKit shows on touch and hold.
  - While the token may not send, the toolbar holds `filterItem` and the search item only. The "Sending Unavailable" item goes. Settings explains the restriction.
- **Title.** `title = scopePresentation.title`. "All Documents" by default.
- **Subtitle.** `navigationItem.subtitle` and `largeSubtitle` hold one line, chosen in this order:
  1. `LibraryScopePresentation.textIndexingNotice` while it is not nil.
  2. `StatusLinePresentation.resolve(...).text` while the copy fills, the archive is unreachable or deferred, or the token is suspended. "Loading · 120 of 5,000", "Offline · updated 09:12".
  3. `DocumentFormatting.countText(listing.documentCount, singular: "document")`.

iOS 18:

- The search bar stays stacked under the large title, as today, and the toolbar hides while it is active, as today.
- `toolbarItems = [filterItem, .flexibleSpace(), scanItem]`, with `scanItem.style = .done`.
- No subtitle. The attention row below covers the states that need a person.

One `if #available(iOS 26, *)` in `LibraryCommands` chooses between the two toolbars, and one in `LibraryViewController` sets the subtitle and the search placement. No other code of the library asks for the version.

### Where things live

| Thing | Place |
| --- | --- |
| What is on its way | The first section of the library, "Arriving" |
| A connection that needs a person | An attention row above "Arriving", which opens Settings |
| The scope filter | The toolbar's leading button, and a token in the search field |
| Photos and Files | The More menu, and touch and hold on Scan |
| Settings, storage, the token, about | The Settings sheet |
| Editing, deleting, retrying | "Open in Browser" at the foot of a document's details, with a sentence that says so |

### The attention row

`LibraryItem` gains a case `attention(ConnectionAttention)`, in a section of its own above everything. It shows while `ConnectionCondition` is `suspended` or `archiveOutdated`.

| Condition | Symbol | Text | Secondary text | Tap |
| --- | --- | --- | --- | --- |
| `suspended(.credentialRefused)` | `exclamationmark.triangle.fill` in `attentionText` | Token Refused | The archive no longer accepts this iPhone's token. Replace it to send and to read new documents. | Settings, pushed to the replace-token form |
| `suspended(.credentialInsufficient)` | the same | Token Lacks Permission | This token can no longer read your archive. Replace it. | the same |
| `archiveOutdated` | the same | Archive Update Required | Update your archive, then open Schublade again. | none |

The row is a `UIListContentConfiguration.subtitleCell()` with a disclosure indicator where it has a tap. It fixes today's dead end.

### First launch

`ConnectionFormViewController` replaces `ConnectionViewController`. One screen, no pages to swipe, no navigation bar.

```text
┌──────────────────────────────────────────┐
│                                          │
│                 ┌─────┐                  │
│                 │ icon│  88 pt           │
│                 └─────┘                  │
│          Connect Your Archive            │  title1, bold
│   Schublade sends your letters to your   │  body, secondaryLabel
│   own archive and keeps every document   │
│        at hand, even offline.            │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │ ▣  Scan Connection Code            │  │  filled, large, after I6
│  └────────────────────────────────────┘  │
│  In your archive's Settings in the       │  footnote
│  browser, issue a token for this iPhone  │
│  and point the camera at its code.       │
│                                          │
│  OR ENTER IT BY HAND                     │
│  ┌────────────────────────────────────┐  │
│  │ Address   https://archive.example… │  │  inset grouped rows
│  │ Token     ••••••••••••      Paste  │  │
│  └────────────────────────────────────┘  │
│  ┌────────────────────────────────────┐  │
│  │             Connect                │  │  tinted after I6, filled before
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
```

- It is a `UICollectionView` with an inset grouped list layout, so it scrolls above the keyboard. The header is a supplementary view with the icon, the title, and the sentence, centred.
- The icon is the application's icon as an image asset `ApplicationIconPicture`, 88 points, `cornerRadius` 20, `cornerCurve = .continuous`.
- The fields are list cells with a `UITextField` as the value. The address field has `keyboardType = .URL`. The token field is secure and has no `textContentType`, so the system does not offer to save it as a password.
- "Paste" is a `UIPasteControl` with `displayMode = .labelOnly` whose target is the token field, so the system shows no paste banner.
- A refusal shows as the section's footer in `systemRed` at `footnote`, with `UINotificationFeedbackGenerator().notificationOccurred(.error)` and a VoiceOver announcement of the sentence. The sentences are `ConnectionWording`'s, unchanged.
- While it connects, the Connect button shows its activity indicator and both fields are disabled.
- "Scan Connection Code" carries `qrcode.viewfinder` and presents `DataScannerViewController` for `.barcode(symbologies: [.qr])` and accepts only a `schublade://connect` address. `SceneDelegate` accepts the same address through `scene(_:openURLContexts:)`, so a link on the website opened on the phone connects with one tap. Both need the website half of unit I6. Until it lands, the button and its footnote are absent, Connect is filled, and the layout is otherwise the same.
- After a successful connection the root shows the library, whose empty state takes over.

---

## 3. Capture

### How Scan is presented

- `VNDocumentCameraViewController`, full screen, unchanged. Schublade adds no review screen and no camera of its own.
- From the Scan button, the camera presents animated.
- From a scan request that started the application, the camera presents with `animated: false` and does not wait for the core. `RootViewController` reads `SharedContainer.connectedArchive()`, which is a file read. When the record names an unrestricted archive, it installs the library and presents the camera in the same turn. A submission needs only the queue, and `SubmissionCoordinator` sends once the core reports the origin.
- From a scan request on a restricted token, the library presents a `UIAlertController` titled "This iPhone Cannot Send" with the restriction sentence of section 7 and OK.

The target is that the viewfinder is live within one second of a tap on the quick action on the owner's iPhone. That number is a target to measure on the device, not a measurement.

### No instant scan on launch

I weighed it and decided against it.

- For it: one tap fewer on the application's first job.
- Against it: the same icon opens the library, and a person who opens Schublade to find last month's invoice would dismiss a camera first, every time. The first launch would ask for the camera before the person has seen what the application is. A camera that opens on its own in a room is a surprise that people remember.
- The fast paths exist and are explicit: the Home Screen quick action, the Control Center and Lock Screen control, the Action button, Siri, and Shortcuts. Each states the intent to scan, and each now reaches the camera without showing the library first.

From the library, Scan is one tap at the thumb's corner. Settings lists the fast paths, so a person learns that they exist.

### What happens after Save

The sequence on a scan of three pages, on Wi-Fi:

| Moment | What the person sees and feels |
| --- | --- |
| Save | The camera dismisses. During the dismissal the list scrolls to its top and a row slides in at the top of "Arriving": the first page as its picture, "Scan", "3 pages · 09:12", "Preparing". `UIImpactFeedbackGenerator(style: .medium).impactOccurred()` fires as the row lands. |
| The PDF is written and queued | The third line becomes "Waiting to send", or goes straight to "Sending". |
| Upload under way | "Sending", and a 22-point ring at the trailing edge fills with the fraction sent. |
| The archive answers `accepted` | The ring fills and is replaced by `checkmark.circle.fill` in the tint, with `.replace` as the symbol content transition. The third line becomes "Sent". |
| The copy holds the document, still in ingestion | The third line shows `LibraryFailureWording.stageText`: "Extracting text", "Recognizing text", "Classifying document", in the tint. |
| The archive has classified it | The row cross-dissolves in 0.25 s to the document: the archive's picture, the real title, the sender and date, the amount. The checkmark bounces once. `UINotificationFeedbackGenerator().notificationOccurred(.success)` fires, and VoiceOver announces "Archived as" and the title. Both happen only while the scene is active. |
| The person leaves the application | The row is removed from "Arriving". The document stays in its month. |

The rule for removal is one line: when the scene enters the background, `SubmissionCoordinator` removes every submission whose document the copy holds as archived or failed. A document that finished while the application was away is therefore shown once, filed, at the next opening, and is gone at the one after. The seven-day expiry stays as the backstop.

### The data shape

`SubmissionRowWording.RowContent` becomes an `Arrival`, resolved in one pure function from a `SubmissionEntry`, its sent fraction, and the document's detail when the copy has one.

```swift
enum ArrivalStage: Equatable {
	case preparing
	case waiting
	case sending(fraction: Double?)
	case retrying(at: Date)
	case sent
	case reading(IngestionStage)
	case filed(DocumentRowPresentation)
	case alreadyHeld(DocumentRowPresentation?)
	case notAccepted(reason: String)
	case tokenRefused
	case failed(FailureReason)
}
```

`SubmissionCoordinator` reads `gateway.document(_:)` for each submission with an archived answer whenever `contentRevision` changes. A day's submissions are a handful, so this is a few local reads.

### The arrival row in every state

An arrival uses the same content view as a document row (section 4), so the picture and the text do not move when it becomes the document.

| Stage | Title | Second line | Third line, colour | Trailing |
| --- | --- | --- | --- | --- |
| `preparing` | display name | facts | Preparing, secondary | spinner |
| `waiting` | display name | facts | Waiting to send, secondary | none |
| `sending` | display name | facts | Sending, secondary | ring |
| `retrying` | display name | facts | Waiting for the archive. Trying again at 09:20. secondary | none |
| `sent` | display name | facts | Sent, tint | checkmark |
| `reading` | display name | facts | the stage text, tint | checkmark |
| `filed` | the document's title | sender · date, amount | none | checkmark until removal |
| `alreadyHeld` | the document's title | sender · date, amount | Already in the archive, secondary | none |
| `notAccepted` | display name | facts | Not accepted. and the archive's reason, `attentionText` | `exclamationmark.circle.fill` |
| `tokenRefused` | display name | facts | The archive refused the token. `attentionText` | `exclamationmark.circle.fill` |
| `failed` | the title, or the display name | facts | `LibraryFailureWording.failureText`, `attentionText` | `exclamationmark.circle.fill` |

- **Display name.** "Scan" for a scan, "Photo" for a photo from the library, and the file name without its extension for a file or a share. The archive still receives the full file name.
- **Facts.** "3 pages · 09:12" for a scan. The size from `ByteCountFormatter` and the time for anything else: "1.2 MB · 09:12".
- **Picture.** `SubmissionQueue.enqueue` writes `thumbnail.jpg` into the submission's directory: the first page, at most 312 pixels on its longer side, JPEG quality 0.8. A scan takes it from the first `UIImage`. A PDF or picture from a share or an import takes it from `QLThumbnailGenerator`. The share extension writes it the same way, so a shared file has its picture when the application opens. The file survives the removal of `document.*`. Once the copy holds the document, the row shows the archive's thumbnail.
- **Ring.** A `CircularProgressView` of 22 points: a `CAShapeLayer` track in `tertiarySystemFill`, a stroke in `tintColor`, line width 2.5, round caps. The stroke animates to each new fraction in 0.2 s.
- **Tap.** A row with a document opens its page, as today. A `tokenRefused` row opens Settings at the replace-token form. Other rows do not select.
- **Swipe.** "Remove" (`trash`, destructive) on every arrival that the archive has not archived, as today. A `notAccepted` row adds "Share" (`square.and.arrow.up`), which hands `submissions.documentFile(of:)` to `UIActivityViewController`.
- **Section.** The header reads "Arriving". The section holds this iPhone's arrivals, newest first, followed by the listing's rows under `ListingHeading.arriving` that no arrival already shows. The listing's own "Arriving" header is not drawn a second time.
- **In a scope and in search.** Arrivals show in every scope while a person browses, and are hidden while a person searches, as today.

### Photos, Files, and the share sheet

They produce the same arrivals with the same row. An import of several files inserts its rows in one snapshot and fires one medium impact.

---

## 4. The library list

### Row anatomy

One content view, `DocumentRowContentView`, draws documents and arrivals from one value.

```text
16 ┌──────┐ 12  Title in headline, at most two lines, full width
   │      │     Sender · 31 Oct                      29.63 EUR
   │ 44×58│     Third line in footnote, at most two lines
   └──────┘                                                  16
```

| Element | Style | Colour | Lines |
| --- | --- | --- | --- |
| Picture | 44 × 58 points, `cornerRadius` 6, `cornerCurve = .continuous`, 0.5-point edge in `pictureEdge` | on `paper` | |
| Title | `headline` | `label` | 2 |
| Sender and date | `subheadline` | `secondaryLabel` | 1, the sender truncates and the date does not |
| Amount | `subheadline`, monospaced digits, medium weight | `label` | 1, trailing on the sender's line, never truncates |
| Third line | `footnote` | by tone: `secondaryLabel`, `tintColor`, `attentionText` | 2 |

- Vertical margins are 10 points. The spacing between lines is 3 points.
- The amount moves from the title's line to the sender's line. The title then takes the full width, and the amounts of all rows form one column at the trailing edge.
- **The third line shows only when it adds something.** While a person browses, an archived document has no third line, so the summary that repeats the title goes. A document in ingestion or failed shows its stage or failure. In a search, the row shows the excerpt or the summary, as today.
- **Short dates under a month.** Under a `ListingHeading.period` heading the date is the day and the month, "31 Oct", because the heading holds the year. Everywhere else it is the full date. This needs one function in `library_presentation/DocumentFormatting.swift`, `dayAndMonth(_:context:)`.
- A row is 78 points with a one-line title and 87 with two, at the default text size. About eight rows fit where five and a half fit today.
- **Without a picture.** A rounded rectangle in `secondarySystemFill` with `doc.text` in `tertiaryLabel` at `title3`. The floating blue icon goes.
- **Fill, from the top.** `ThumbnailStore` crops a picture to 44:58 from its top edge when it decodes it, so a letterhead is always in view and no picture is letterboxed.
- No disclosure indicator. A full-width row in a plain list is understood as tappable.

### Section headers

- `UIListContentConfiguration.header()`, as today. "Arriving", then the months, "October 2026".
- In a search: "Matches in Details" and "Matches in Text", as today.
- Headers pin while their section scrolls, which a plain list does by default.

### Search

- Placeholder "Search".
- **The scope is a token.** While a scope other than All Documents is chosen and the search is active, `searchBar.searchTextField.tokens` holds one `UISearchToken` with the scope's symbol from `LibraryScopeMenu` and its name. Deleting the token chooses All Documents. This is the only place the scope shows while the stacked search bar of iOS 18 hides the title.
- **Suggestions offer a scope.** While the typed text is a prefix of a category's, a tag's, or a person's name, ignoring case and diacritics, `searchController.searchSuggestions` holds up to three `UISearchSuggestionItem`s, each with the name, the kind as its description ("Category", "Tag", "Person"), and the symbol. Choosing one clears the text, chooses the scope, and inserts the token. The facets hold no senders, so a sender is never suggested.
- **The excerpt marks what matched.** In a row under "Matches in Text", each occurrence of a search term in the excerpt is drawn in `label` at semibold weight. The comparison ignores case and diacritics. The rest stays `secondaryLabel`.
- **A text match opens on the match.** A row under "Matches in Text" opens its document's text page with the find navigator showing the search text (section 5).
- The 250 ms pause, the "Search All Documents" button of the empty result, and the hidden arrivals stay as they are.
- No scope bar. Its segments are fixed, and the scopes are a list the household makes.
- No recent searches.

### The scope menu

`LibraryScopeMenu` stays a `UIMenu`, with two cuts.

- "Arriving" leaves the menu, because the section on top of All Documents shows the same documents.
- "Failed Documents" shows only while `facets.documentsFailed > 0`.

So the menu is: All Documents, Recently Added, Failed Documents when there are any, then Household and People, then Categories and Tags.

### Swipe actions

- A document row has one trailing action, "Share" (`square.and.arrow.up`, background in the tint). It presents `UIActivityViewController` with the named copy, as the document page's Share does. `performsFirstActionWithFullSwipe` is false, because a full swipe that opens a sheet surprises.
- No leading action. The phone cannot delete, flag, or mark, and an action row with nothing behind it is clutter.
- "Copy Amount" is not a swipe action. Paying a bill needs the IBAN, the amount, and the invoice number, and the details sheet offers the three together.

### Context menu

`collectionView(_:contextMenuConfigurationForItemsAt:point:)` on a document row.

- **Preview.** A `DocumentOriginalViewController` with `preferredContentSize` of the row's width by that width times 1.414. It shows the cached picture scaled up until the original has loaded.
- **Actions.** "Share…" (`square.and.arrow.up`). "More from" and the sender's name (`building.2`), from a `UIDeferredMenuElement.uncached` that reads `gateway.document(_:)`, which chooses the sender's scope. "Open in Browser" (`safari`).
- A tap on the preview pushes the document page through `collectionView(_:willPerformPreviewActionForMenuWith:animator:)`.

### Empty states

All are `UIContentUnavailableConfiguration`, as today.

| State | Image | Text | Secondary text | Button |
| --- | --- | --- | --- | --- |
| Empty archive, may send | the drawer glyph, 64 points, `tertiaryLabel` | No Documents Yet | Scan a letter, or share a PDF or photo with Schublade. Your archive reads it, names it, and files it. | Scan, filled, capsule, `doc.viewfinder` |
| Empty archive, restricted | the same | No Documents Yet | Documents added to your archive in the browser appear here. | none |
| First copy filling | `.loading()` | Loading Documents… | the status line's text | none |
| Empty scope | `tray` | `EmptyListPresentation`'s title | its detail | none |
| No result | `.search()` | `EmptyListPresentation`'s title | its detail | Search All Documents, where it applies |
| Listing failed | `exclamationmark.triangle` | the fault's title | its sentence | none |

- The drawer glyph is the Mac's `menu_bar_template.svg` as a template image asset, `DrawerGlyph`.
- While the archive is empty, `filterItem` is hidden. The Scan button in the middle and the one in the toolbar both stay. A first-time person looks at the middle, and the toolbar should not change shape after the first scan.

### Pull to refresh

`UIRefreshControl`, as today. It ends when the copy has read the archive, or at once when the archive is out of reach, and the subtitle then reads "Offline · updated 09:12".

---

## 5. The document page

### Hierarchy

```text
┌──────────────────────────────────────────┐
│ ( ‹ )  Mühlbach Bank Account Statemen…   │  inline title
│        Mühlbach Bank AG · 31 Oct 2026    │  subtitle, iOS 26
│ ┌──────────────────────────────────────┐ │
│ │                                      │ │
│ │        the original, edge to edge    │ │  PDFView or the picture
│ │                                      │ │
│ ├──────────────────────────────────────┤ │
│ │               ▂▂▂                    │ │  details sheet, medium detent
│ │ Mühlbach Bank Account Statement      │ │
│ │ October 2026                         │ │
│ │ Bank Statement from Mühlbach Bank AG.│ │
│ │ ┌──────────────────────────────────┐ │ │
│ │ │ IBAN    DE72 9605 1240 0471 …  ⧉ │ │ │
│ │ └──────────────────────────────────┘ │ │
│ ( ↑ )                          ( ⓘ )     │  toolbar
└──────────────────────────────────────────┘
```

- The original fills the page, under both bars. The segmented control and its bar go.
- The details are a sheet. The text is a page of its own, one step further: the owner reads the original and the details often and the extracted text rarely, so the text is findable but not prominent (owner, 2026-11-23).
- The title is in the bar, truncated, for orientation. Its one full statement is the head of the details sheet. The card that repeats it goes.

A persistent sheet at half height is the phone's form of the Mac's reader with its inspector: the top of the letter and the facts are on the screen together. A segmented control makes the person choose one.

### The navigation bar

- `navigationItem.title` is the document's title, `largeTitleDisplayMode = .never`.
- `navigationItem.subtitle`, from iOS 26, is the sender and the full date, "Mühlbach Bank AG · 31 Oct 2026". The page count leaves it, because it is what truncated.
- The back button is `.minimal`, as today.

### The toolbar

`toolbarItems = [shareItem, .flexibleSpace(), detailsItem]`. The text has no toolbar item.

| Item | Symbol | Title | Behaviour |
| --- | --- | --- | --- |
| `shareItem` | `square.and.arrow.up` | Share | `UIActivityViewController` with the named copy, as today |
| `detailsItem` | `info.circle` | Details | Presents or dismisses the sheet. The sheet's copy is `.prominent` from iOS 26, because a selected item draws its tint as a disc of its own that the glass leaves behind when the sheet moves it, and `isSelected` before |

Quick Look goes, because it showed the same file as the page under it. Printing and Markup remain in the share sheet. "Open in Browser" moves to the foot of the details.

### The original

- `PDFView` and `ZoomingPictureView`, as today, with their frame equal to the page's bounds, so the content scrolls under the bars and the system draws the scroll edge effect.
- The backdrop stays `InterfacePalette.readerBackdrop`.
- While the sheet shows, `additionalSafeAreaInsets.bottom` of the original is the sheet's height at the medium detent, so the last lines of a page scroll above the sheet.
- The loading, unavailable, and not-yet-printed states stay as they are. The unavailable state of a failed document adds a plain button "Open in Browser".

### The details sheet

`DocumentDetailsViewController`, presented by the page.

- `sheetPresentationController`: `detents = [.medium(), .large()]`, `prefersGrabberVisible = true`, `largestUndimmedDetentIdentifier = .medium`, `prefersScrollingExpandsWhenScrolledToEdge = true`.
- The collection view's background is clear from iOS 26 at the medium detent, so the sheet's glass shows, and `systemGroupedBackground` at the large detent, where the opaque sheet is as white as the rows in the light appearance, and before iOS 26.
- The sheet has no bar, so from iOS 26 a gradient mask clears the top 12 points under the grabber and fades the next 16, and a list scrolled up never runs under the grabber.
- **It remembers.** `UserDefaults` holds `document.detailsShown`, true by default. Opening the sheet sets it and dismissing the sheet clears it. A page whose detail has loaded presents the sheet at the medium detent in `viewDidAppear` while the value is true. The Mac's inspector starts visible too.
- `viewWillDisappear` dismisses the sheet with the same `animated` flag. A back swipe that the person cancels brings `viewDidAppear` again, which presents it again.

Its list, inset grouped:

1. **Head**, with a clear background. The title in `title3` semibold, up to four lines. Under it the summary in `subheadline`, `secondaryLabel`.
2. **Facts**, without a header: every `InspectorDetailRow` that has no `linkedScope`, in the presentation's order. Date, Amount, Due, IBAN, Invoice, Customer, Policy, and the others.
3. **Filed under**: every row with a `linkedScope`. Sender, Category, Person. Each has a disclosure indicator. A tap dismisses the sheet, pops to the library, and chooses the scope, as today.
4. **Tags**, while the document has any, one row a tag, with a disclosure indicator.
5. **File**: the file facts, then a row "Extracted Text" (`text.page`, disclosure indicator) that pushes the text page, then a row "Open in Browser" (`safari`, text in the tint). The section's footer reads "Edit the details, retry, or delete this document in your archive in the browser."

Rows:

- `UIListContentConfiguration.valueCell()`. The label is `secondaryLabel`. The value is `label`. An amount and an IBAN use monospaced digits. `prefersSideBySideTextAndSecondaryText` keeps its default, so a row stacks at the accessibility sizes.
- The link colour goes from the values. The disclosure indicator says that a row leads somewhere.
- **A tap copies a fact.** Every row of Facts carries a trailing `doc.on.doc` in `tertiaryLabel`. A tap writes `copyValue` to the pasteboard, fires `UIImpactFeedbackGenerator(style: .light)`, and for one second the value reads "Copied" in the tint and the symbol is `checkmark`, both with a cross-dissolve. VoiceOver announces "Copied". The touch-and-hold menu with Copy stays on every row for people who know it.
- The IBAN copies without spaces, as `copyValue` gives it today.

### The text

`DocumentTextViewController`, a `UITextView`, pushed onto the page's navigation stack with the title "Text". It is reached three ways, none of them on the page itself:

- an "Extracted Text" row (`text.page`, with a disclosure indicator) in the details sheet, in the section with "Open in Browser"; tapping it dismisses the sheet and pushes the text, and Back returns to the original with the sheet as the person left it;
- a row under "Matches in Text", which opens the document page and the text page above it in one push, with the find navigator on the term;
- for VoiceOver, an accessibility custom action "Show Text" on the original, because for a VoiceOver user a scan's text is the document.

The page itself:

- Body text in `body`, `label`, with `lineHeightMultiple` 1.15 and `paragraphSpacing` 8.
- `textContainerInset` is 16 on top, 24 at the bottom, and the sides follow `readableContentGuide`, at least 20.
- A line "## Page 2" or "### Page 2" is a page mark: `footnote`, semibold, `secondaryLabel`, with 24 points above it. Any other heading is `headline`.
- Inline Markdown is read with `AttributedString(markdown:options:)` and `.inlineOnlyPreservingWhitespace`, a line at a time.
- A table row, a line that starts with "|", is drawn in the monospaced system font at the `footnote` size. A separator row of dashes is dropped. No table layout is built.
- The system sans serif stays. Invoices are numbers in columns, and a serif face would serve the three paragraphs of a letter at the cost of the figures.
- `isFindInteractionEnabled = true`. A page opened from a row under "Matches in Text" starts in the text, sets `findInteraction.searchText` to the search text, and calls `presentFindNavigator(showingReplace: false)`.
- The custom action's name is "Show Text", and the row's hint says "Shows the text the archive read from this document."

### Arriving, failed, absent

The page's states stay as they are: "Arriving in Your Library" while the copy lacks the document, and "Document Unavailable" for a fault. No sheet is presented in either.

### The transition

- From iOS 18, the page sets `preferredTransition = .zoom(sourceViewProvider:)`, and the provider returns the picture view of the row for the document. The picture grows into the page, and a pinch or a pull down returns it.
- `UIAccessibility.isReduceMotionEnabled` leaves `preferredTransition` nil, which is the standard push.
- **This is the one part to try before keeping.** The zoom's interactive dismissal and the presented sheet meet in `viewWillDisappear`. Build the sheet first. Then add the zoom and pull a page down ten times with the sheet up. If the sheet ever stays over the library, or the pop stalls, remove the zoom and keep the push. The sheet matters more.

---

## 6. The share extension's sheet

### What the system allows

The system presents a share extension's view controller as a full-height page sheet, which `sheet.png` shows. The presentation belongs to the host application's process, so I expect the extension's root to have no `sheetPresentationController` to give detents to. That is from memory and I did not run it. The first step of unit D4 is to read `sheetPresentationController` in `viewIsAppearing` on the simulator. If it is not nil, set `detents = [.medium(), .large()]`. If it is nil, the sheet stays full height. The layout below works at both heights, because it fills the height it gets with what the person needs to see, the pictures of what is being sent.

### Layout

```text
┌──────────────────────────────────────────┐
│ ( ✕ )          Schublade        ( Send ) │
│                                          │
│        ┌────────┐ ┌────────┐ ┌─────      │
│        │        │ │        │ │           │  the files, scrolling sideways
│        │  page  │ │  page  │ │           │
│        └────────┘ └────────┘ └─────      │
│         Invoice    IMG_0412              │
│                                          │
│              3 documents                 │  headline
│   to your archive at archive.example.org │  subheadline, secondaryLabel
│                                          │
│  Schublade sends only PDFs and pictures, │  footnote, secondaryLabel
│  so it leaves out Notes.txt.             │
└──────────────────────────────────────────┘
```

- **Bar.** Cancel is `UIBarButtonItem(systemItem: .cancel)`. Send is `style = .prominent` from iOS 26 and `.done` before, in the application's tint. The extension gets the `AccentColor` asset through its own asset catalogue and `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in `project.yml`, which removes the cyan text.
- **Pictures.** A `UICollectionView` with one horizontally scrolling section. One file is a single tile of 200 × 260 points, centred. Two or more are tiles of 120 × 156 with 12 points between them and 20 points before the first. A tile is a picture on `paper` with `cornerRadius` 8, the continuous curve, and the 0.5-point edge. Under a tile of a file, its name in `caption1`, one line, truncated in the middle. A photo has no name line.
- **Where the pictures come from.** On appearance the extension copies each accepted file into its working directory, one at a time, as `send` does today, and asks `QLThumbnailGenerator` for the picture, which the system renders outside the extension's memory. Send then uses the copies. A tile shows `doc.richtext` or `photo` in `tertiaryLabel` until its picture arrives.
- **The destination.** "1 document" or "3 documents", then "to your archive at" and the host. The protocol gives the archive no name, only the token a description, so "your archive" is the name and the host is the detail. A port shows only when the origin names one.
- **Left out.** The sentences of `refusalSentence` stay, as the footnote.

### States

| State | What shows |
| --- | --- |
| Ready | The layout above, Send enabled |
| Sending | Send is replaced by a `UIActivityIndicatorView` item, Cancel is disabled, the sheet refuses the swipe, as today. The headline reads "Sending 2 of 3…". Each tile gains a `checkmark.circle.fill` badge in the tint at its lower trailing corner when its upload has started |
| On its way | The pictures stay. The headline reads "On its way to your archive." with `checkmark.circle.fill` in the tint above it, which bounces once. `UINotificationFeedbackGenerator().notificationOccurred(.success)`. The sheet completes the request after 0.8 s |
| Some files unreadable | The sentence of `showUnsent`, the tiles of the unsent files marked with `exclamationmark.circle.fill` in `attentionText`, and Done. `.warning` haptic |
| No archive connected | `UIContentUnavailableConfiguration`: `tray`, "No Archive Connected", "Open Schublade and connect your archive, then share again.", and Cancel only |
| Restricted token | The same form: `lock`, "This iPhone Cannot Send", the restriction sentence of section 7 |
| Nothing it can send | The same form: `doc.questionmark`, "Nothing to Send", "Schublade sends PDFs and pictures, and none was shared." |
| The shared container is missing | The same form, with today's sentence |

"On its way" is the honest word. The extension has handed the files to a background session, and the archive has not answered yet. The application's "Arriving" section shows the rest.

---

## 7. Settings

A sheet with a large detent only. A `UINavigationController` whose root is `SettingsViewController`, an inset grouped `UICollectionView` list. The title is "Settings", inline. The trailing bar item is Done.

### Archive

- A row with the host as its text and the status line as its secondary text, with the status line's symbol: `checkmark.circle` "Up to date · 09:41", `wifi.slash` "Offline · updated 09:12", `exclamationmark.triangle.fill` "Token refused". The symbol takes `attentionText` for the last and `secondaryLabel` otherwise.
- "Open Archive in Browser" (`safari`), which opens the origin.
- "Replace Token…" (`key`), which pushes `ConnectionFormViewController` in its replace form: no icon, the title "Replace Token", the address filled in, the token field focused.
- The footer says what the token permits, in one of two sentences.
  - "This iPhone reads your archive and sends documents to it."
  - "This token reads only part of your archive, so this iPhone cannot send documents. To scan and share, replace it with a token without a restriction."

The second sentence is the explanation of a restricted token, everywhere: here, in the scan request's alert, and in the share sheet. `ConnectedArchive.restrictionSentence` takes this wording. Its present middle sentence, "The archive's answer to an upload could name a document outside that part.", explains the implementation and leaves.

Settings has no Disconnect. The core has no command that forgets an archive, and I do not propose one. "Replace Token…" covers a revoked token and a move to another archive, because the replica empties and fills again when the origin differs. Removing the application removes its Keychain item and its copy.

### Storage

- "Keep Originals", with a `UICellAccessory.popUpMenu` over `IphoneDevice.wording.storageLimitChoices`, titled by `StorageWording.limitTitle`: 250 MB, 500 MB, 1 GB, 2 GB, No Limit. It calls `Library.set_original_storage_limit`.
- "Remove Downloaded Originals", text in the tint, which calls `Library.remove_downloaded_originals`. It asks nothing first, because every original downloads again when it is opened.
- The footer is `StorageWording.heldSentence` followed by the Mac's note: "Originals read longest ago go first. Each is downloaded again when you open it."
- `ApplicationGateway` gains the three storage calls, as the Mac's `StorageCommands` has them.

### Scan without opening Schublade

Four rows that do not select, each a symbol, a name, and a secondary line. They are here because the application's fastest paths are invisible from inside it.

| Symbol | Text | Secondary text |
| --- | --- | --- |
| `apps.iphone` | Home Screen | Touch and hold the Schublade icon, then choose Scan Document. |
| `switch.2` | Control Center and Lock Screen | Add the Scan Document control. |
| `button.horizontal.top.press` | Action Button | In the Settings app, choose Shortcut, then Scan Document. |
| `mic` | Siri | Say "Scan with Schublade". |

### About

A footer under the last section, centred: the `ApplicationIconPicture` at 60 points, "Schublade", and the version and build from the bundle in `footnote`, `secondaryLabel`.

Settings holds nothing else. It has no appearance choice, no icon choice, no sort order, and no notification switch, because the application has none of those to set.

---

## 8. The visual language

### Tint and colour

Native first, with the website's colours, as on the Mac.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `AccentColor`, the window's `tintColor` | `#0B5CBF` | `#3A8EE6` | Every control, the prominent Scan and Send buttons, stage text, "Copied", the checkmark. It is the Mac's `AccentColor` too |
| `InterfacePalette.archive` | `#4A97E3` | `#5CA8F0` | Graphics only: the progress ring. Never text |
| `InterfacePalette.attentionText`, new | `#A85A00` | `#F5A03C` | Failure and refusal text, and their symbols |
| `InterfacePalette.attention` | `#E5850F` | `#F5A03C` | Nothing on the iPhone after this change. Remove it from the iPhone's palette |
| `InterfacePalette.link` | `#0B57B0` | `#7DB8FF` | Nothing on the iPhone after this change. Remove it from the iPhone's palette |
| `paper`, `pictureEdge`, `readerBackdrop` | unchanged | unchanged | Pictures and the reader |

Why the tint is `#0B5CBF` and not the archive blue `#4A97E3`: white text on `#0B5CBF` measures 6.37:1, and on `#4A97E3` it measures 3.08:1. As text on white, `#4A97E3` measures 3.08:1 and `#E5850F` 2.73:1. `#A85A00` measures 5.09:1 on white and 4.56:1 on the grouped background `#F2F2F7`. In the dark, `#3A8EE6` measures 6.19:1 and `#F5A03C` 9.98:1 on black.

Everything else is a system colour: `label`, `secondaryLabel`, `tertiaryLabel`, `systemBackground`, `systemGroupedBackground`, `secondarySystemFill`, `systemRed` for a form's error. No view holds a colour literal.

### Typography

System text styles only, each label with `adjustsFontForContentSizeCategory = true`. The styles are named in each section above. Two rules apply everywhere.

- Numbers that a person compares or copies use monospaced digits: amounts and IBANs.
- No custom font and no fixed point size, except through `UIFontMetrics`.

### Dynamic Type

- Nothing has a fixed height. The picture of a row scales with `UIFontMetrics(forTextStyle: .body).scaledValue(for: 44)` up to 66 points wide.
- At an accessibility size, read from `traitCollection.preferredContentSizeCategory.isAccessibilityCategory`, a row changes shape: the title takes up to four lines, the sender up to two, and the amount moves to a line of its own under the sender, leading. The date joins the amount's line.
- The welcome screen and Settings are lists, so they scroll.
- The bars' items carry titles, so the large content viewer shows them.
- Each unit's proof includes its main screen at the largest accessibility size.

### Liquid Glass and iOS 18

- The bars, the menus, and the sheets take the glass from the system on iOS 26. The application sets no `UINavigationBarAppearance`, no bar background, and no blur of its own.
- Content scrolls under the bars: the list, the original, and the text. No opaque band sits between a bar and the content.
- Glass is for the layer of controls. Rows, pictures, and the empty state's button are content and use no glass. The button in the empty state is `.filled()`.
- One prominent item on a screen: Scan in the library, Send in the share sheet.
- Symbols inside a bar item are the plain variants, never `.circle`.
- The version checks are five: the library's toolbar and search placement, the two subtitles, `.prominent` against `.done`, and the clear background of the details sheet. On iOS 18 the same view controllers show the standard translucent bars.

### Dark mode

Every colour above is dynamic. A page and its picture stay white in the dark, because they are paper. Each unit's proof includes its main screen in the dark.

### The icon

- The icon is the brand. It appears on the Home Screen, as the hero of the welcome screen, and in the footer of Settings. Its drawer, as a one-colour glyph, is the picture of the empty archive.
- The name "Schublade" appears under the icon on the Home Screen, in the share sheet's title, and in Settings. It is not a navigation title.
- `AppIcon.appiconset` gains the dark and the tinted variants that iOS 18 introduced, rendered from `application_icon.svg`: the dark one with the plate in `#0B2447` going to black, and the tinted one in greys. Without them the system darkens the flat picture itself.

### Haptics

One file, `Haptics.swift`, with one function per moment, so no screen picks a generator on its own.

| Moment | Generator |
| --- | --- |
| An arrival's row lands | `UIImpactFeedbackGenerator(style: .medium)` |
| An arrival becomes its document, scene active | `UINotificationFeedbackGenerator`, `.success` |
| An arrival is not accepted or the token is refused, scene active | `UINotificationFeedbackGenerator`, `.error` |
| A fact is copied | `UIImpactFeedbackGenerator(style: .light)` |
| The share sheet has handed everything over | `.success` |
| The share sheet could not read a file | `.warning` |
| A connection is refused | `.error` |

No sound.

### Motion

| Change | Motion |
| --- | --- |
| Rows inserted, removed, moved | The diffable data source's own animation |
| The ring fills | 0.2 s, ease out |
| The ring becomes a checkmark | Symbol content transition `.replace` |
| A row becomes its document | Cross-dissolve of the cell's content, 0.25 s, then `.bounce` once on the checkmark |
| The original and the text swap | Cross-dissolve, 0.2 s |
| A document opens | The zoom transition, subject to the trial in section 5 |
| "Copied" | Cross-dissolve, 0.15 s in and out |

With Reduce Motion on: no bounce, no zoom, and the cross-dissolves stay.

### VoiceOver

- A document row is one element. Its label is the title, the sender, the date, and the amount, in that order. Its value is the third line. Its custom actions are Share and "More from" the sender.
- An arrival row is one element with the `updatesFrequently` trait. Its label is the display name and the facts. Its value is the stage, with "42 per cent" while it sends.
- A picture is not an element.
- A fact row has the button trait and the hint "Copies the value."
- A scope row has the hint "Shows the documents of" and the name.
- The attention row is announced when it appears.
- Every bar item has a title, as today.

---

## 9. Small delights

### Kept, because each serves the loop

1. **A letter becomes its document in one row.** The picture at once, the ring, the stages, the real title. Loop steps 1 and 2.
2. **The camera before the library** from the control, the Action button, and the quick action. Step 1.
3. **Haptics at the two moments that matter**: the letter is safe on the phone, and the letter is filed.
4. **A text match opens on the match**, with the words marked in the row and found in the text. Step 3.
5. **Tap a fact to copy it**, with "Copied" in its place for a second. Step 3, when a bill is paid.
6. **Type "rec" and get the Receipt scope** as a token. Step 3.
7. **Touch and hold Scan** for Photos and Files.
8. **The page grows out of its picture**, if the trial holds.

### Cut

| Idea | Why not |
| --- | --- |
| A camera on every launch | Section 3 |
| A camera or review screen of Schublade's own | The system's camera crops, filters, and retakes. A second screen is the step this application removes |
| A Live Activity for an upload | It needs SwiftUI in an extension, and an upload on Wi-Fi takes seconds. Measure a 20 MB scan on a mobile network on the owner's iPhone before it is worth a second look |
| Home Screen widgets | SwiftUI, and reading a document from a widget is not the loop |
| Notifications | A local notification for a refused upload would serve "nothing is lost", but it costs a permission prompt. Revisit after the owner has used a build for a week and says whether a failure went unseen |
| A sort menu | The months and "Recently Added" cover it. `ListingOrder.title` and `.sender` stay unused on the phone |
| The Quick Look button | It showed the same file as the page |
| Tap to hide the bars | The bars are glass over the content on iOS 26, and it is one more hidden gesture |
| Swipe to delete, select, batch actions | The phone does not edit the archive |
| Tips, a tour, onboarding pages | One welcome screen and one empty state say what to do |
| Alternate icons, themes, a serif reading face | The application has one look |
| A badge on the filter for failed documents | The phone cannot retry, so the badge could not be cleared from the phone |
| Disconnect | No command in the core, and Replace Token covers the cases |

### SwiftUI

Nothing in this direction needs SwiftUI. The interface stays UIKit, and the control extension stays the one SwiftUI target. The two ideas that would need more SwiftUI, the Live Activity and widgets, are cut above.

---

## 10. Build plan

Five units, in the order of the loop. Each ends with `scripts/execute_on_macintosh.sh native_client/iphone_application/scripts/check_application.sh` and one commit on `main`. Each is proven by screenshots from `scripts/start_screen_examination.sh`, taken with `xcrun simctl io <device> screenshot` and driven with `axe`. The paths below are under `native_client/iphone_application/` unless they begin with another directory.

### Unit D1: capture and arrival

The letter is one row from Save to its title.

1. `application_interface/InterfacePalette.swift`: add `attentionText`, remove `attention` and `link` once nothing reads them.
2. `application_interface/Haptics.swift`, new.
3. `submission_queue/SubmissionQueue.swift`, `submission_queue/ShareIntake.swift`: write `thumbnail.jpg` at enqueue, and expose its URL.
4. `application_interface/ArrivalPresentation.swift`, new, in place of `SubmissionRowWording.swift`: `ArrivalStage`, `Arrival`, and the pure function that resolves one. One test per stage of the table in section 3.
5. `application_interface/SubmissionCoordinator.swift`: the `preparing` entry before the PDF is written, the document detail of each archived submission on every `contentRevision`, and the removal of filed submissions when the scene enters the background. `SceneDelegate.swift` calls it.
6. `application_interface/DocumentRowContentView.swift`, `LibraryRowConfiguration.swift`, `CircularProgressView.swift` (new): the one row of section 4 with its trailing accessory. Document rows take the new anatomy here too, because arrivals and documents share the view.
7. `application_interface/LibraryList.swift`, `LibraryListState.swift`: the "Arriving" section that joins both sources, and the swipe actions.
8. `application_interface/DocumentCapture.swift`, `LibraryViewController.swift`, `RootViewController.swift`: the camera from the record without animation on a cold start, the alert for a restricted token, the scroll to top, and the haptics.
9. `native_client/scripted_archive/src/lib.rs`, `src/bin/scripted_archive_server.rs`, `scripts/start_screen_examination.sh`: `/scripted/documents` accepts a status and updates a seeded document, and an uploaded document can be held in ingestion. Today every scripted document is archived at once, so no stage can be shown.

Proof, in light, and the first two also in dark:

- `d1_arrival_sending.png`: a scan with its picture and a part-filled ring.
- `d1_arrival_reading.png`: the same row with "Recognizing text" and the checkmark.
- `d1_arrival_filed.png`: the same row as its document, title and amount.
- `d1_arrival_not_accepted.png` and `d1_arrival_waiting.png`, with the scripted archive stopped by `kill -STOP`.
- `d1_after_background.png`: the list after the application went to the background and returned, with no filed row on top.
- On the owner's iPhone: the time from the quick action to a live viewfinder, and a three-page scan filmed from Save to its title.

### Unit D2: the library

1. `application_interface/LibraryViewController.swift`, `LibraryCommands.swift`: the title, the subtitle, the More menu, the toolbar with the integrated search field, the iOS 18 branch.
2. `application_interface/LibraryScopeMenu.swift`: the two cuts.
3. `application_interface/LibraryList.swift`, `LibraryListState.swift`: the attention row, the context menu with its preview, the Share swipe.
4. `application_interface/LibrarySearch.swift`, new: the token, the suggestions, and the marking of matched words. One test for the suggestion matching and one for the marking.
5. `native_client/library_presentation/DocumentFormatting.swift`: `dayAndMonth`. One test.
6. `application_interface/ThumbnailStore.swift`: the crop from the top.
7. `application/Assets.xcassets/DrawerGlyph.imageset`, new, from `native_client/macintosh_application/application/menu_bar_template.svg`.

Proof:

- `d2_list_light.png`, `d2_list_dark.png`: eight rows, the title "All Documents", the count, the three-part toolbar.
- `d2_scope_receipt.png`: the title "Receipt" and the selected filter item.
- `d2_search_token.png`: the token "Receipt" in the field with a result.
- `d2_search_suggestion.png`: "rec" typed and the Receipt suggestion.
- `d2_search_text_match.png`: an excerpt with its matched words marked.
- `d2_context_menu.png`: the preview and three actions.
- `d2_attention_token_refused.png`: with the scripted archive started under another token.
- `d2_empty_archive.png`: the drawer glyph.
- `d2_list_accessibility_size.png`: the largest accessibility size.
- No screenshot of the iOS 18 branch, because the Mac has only the iOS 26.5 runtime. The compiler checks the branch. Ask the owner whether to install an iOS 18 runtime before claiming the fallback works.

### Unit D3: the document page

1. `application_interface/DocumentPageViewController.swift`: remove the segments, the full-bleed original, the pushed text page with its three ways in, the sheet's presentation and its remembered state.
2. `application_interface/DocumentDetailsViewController.swift`: the sheet's list, tap to copy, "Open in Browser" with its footer.
3. `application_interface/DocumentPageToolbar.swift`: the three toolbar items, without Quick Look and the browser item.
4. `application_interface/DocumentTextViewController.swift`: the typography, the page marks, the table rows, the find navigator.
5. `application_interface/DocumentOriginalViewController.swift`: the inset under the sheet, the button of a failed document.
6. `application_end_to_end_tests/ApplicationEndToEndTests.swift`: the test that opens a seeded document reads the details from the sheet instead of the segment.
7. Last, the zoom transition and its trial.

Proof:

- `d3_page_with_details_light.png`, `d3_page_with_details_dark.png`: the dental invoice with the sheet at the medium detent, Amount, Due, and IBAN in view.
- `d3_page_original.png`: the sheet dismissed, the page under both bars.
- `d3_details_large.png`: the sheet at the large detent, down to "Open in Browser" and its footer.
- `d3_copied.png`: the IBAN row reading "Copied".
- `d3_text.png`: the text page of a two-page statement with a page mark, reached from the "Extracted Text" row.
- `d3_text_found.png`: opened from "Matches in Text", the find navigator showing the term.
- `d3_details_accessibility_size.png`.
- A sentence in the commit that says whether the zoom stayed, with what the ten pulls showed.

### Unit D4: the share sheet

1. `share_extension/ShareViewController.swift`: the layout, the pictures, the states, the haptics.
2. `project.yml`, `share_extension/Assets.xcassets`, new: the accent colour for the extension.
3. `submission_queue/SharedInstallation.swift`: the restriction sentence of section 7.
4. `application_end_to_end_tests/ShareIntakeTests.swift`: unchanged in what it asserts. It must still pass, because Send now uses files copied on appearance.

Proof, by the route of AGENTS.md, "AXe drives the iPhone simulator":

- `d4_share_one_pdf.png`: one PDF from Safari, its page large, "to your archive at" and the host.
- `d4_share_three.png`: three photos from Photos as tiles.
- `d4_share_on_its_way.png`: the checkmark state, caught with the archive stopped by `kill -STOP`.
- `d4_share_left_out.png`: a text file beside a PDF.
- `d4_share_not_connected.png`.
- On the owner's iPhone: 20 photographs shared at once without the extension ending, because the pictures are a new cost in a process the system ends above about 120 MB.

### Unit D5: first launch and Settings

1. `application_interface/ConnectionFormViewController.swift`, new, in place of `ConnectionViewController.swift`, with its replace form.
2. `application_interface/SettingsViewController.swift`, new, and the three storage calls in `ApplicationGateway.swift`.
3. `application_interface/RootViewController.swift`: the welcome screen, and the 400 ms before a spinner.
4. `application/Assets.xcassets`: `ApplicationIconPicture`, and the dark and tinted variants of `AppIcon`.
5. `application_end_to_end_tests/`: the tests that connect through the form use the new screen's identifiers.
6. After the website half of unit I6: `SceneDelegate.swift` and `ConnectionFormViewController.swift` take `schublade://connect`, and the scan button appears.

Proof:

- `d5_welcome_light.png`, `d5_welcome_dark.png`, `d5_welcome_keyboard.png` with the Connect button above the keyboard, `d5_welcome_refused.png`.
- `d5_settings.png`: the four sections and the footer.
- `d5_settings_restricted.png`: the archive section's footer for a restricted token, with the scripted archive started under one.
- `d5_settings_storage_menu.png`.
- `d5_replace_token.png`.
- `d5_home_screen_dark_icon.png`: the Home Screen in the dark appearance.

### Order and dependence

- D1 changes the row that D2 lays out, so D1 comes first.
- D5 holds the way out of a refused token. If the owner's token is ever refused before D5 lands, the only remedy is to reinstall. Move the Settings sheet and the replace form ahead of D2 if that risk matters more than the order of the loop.
- D4 depends on D1 only for `thumbnail.jpg`.

### After each unit

- `notes/iphone_application_design.md` gets its reconciliation paragraph, as units I1 to I5 have theirs. Its lines on the Sending section, the three segments, and the toolbar's Quick Look and Open in Browser describe the build this direction replaces.
- `AGENTS.md` gets the changed file descriptions of `application_interface/` and `share_extension/`.

## 11. What only the owner's iPhone shows

- The time from the quick action, the control, and the Action button to a live viewfinder.
- The haptics. The simulator plays none.
- The glass over a real scan in daylight, and the tint against it.
- The share sheet's memory with 20 photographs.
- Whether the zoom transition and the details sheet hold together under a thumb.
