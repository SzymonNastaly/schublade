# Schublade for Mac: design direction

Written on 2026-11-23 against commit `f0dd31b`. It is a direction for implementers, not code. It follows the shape of `notes/iphone_interface_direction.md` and keeps the product scope of `notes/native_client_design.md`.

## The goal

The owner wants the Mac application to be as good as the iPhone application became this week: true to the Human Interface Guidelines, understood without instructions, and with the care of the Mac applications of small studios. Direction A, chosen on 2026-11-22, stands. The window is native AppKit, and the website is present only as colour.

The Mac serves one loop, in this order of importance.

1. A person finds a document and reads it. The person walks the list with the arrow keys or types a word, reads the page, and copies an amount or an IBAN to pay a bill.
2. The person sees what arrived, in the list, under Recently Added, and in the menu bar.
3. The Mac collects folders unattended. Schublade speaks only when a folder needs a decision or the archive refuses the token.

`notes/native_client_design.md` states the same three in "The product and its first version". Revising, deleting, retrying, tokens, and uploads by hand stay in the browser. This direction proposes no change of scope.

## What this direction rests on

- I looked at every file of `.audit/macintosh_baseline/`: 22 offscreen renders of the build at `f0dd31b` in both appearances, the two sheets of menu bar glyphs, `status_item_menu.txt`, and the 21 captures of the real screen in `screen/`.
- The offscreen renderer paints a stand-in toolbar and a flat sidebar, so every statement about the toolbar, the glass, and the menus comes from the captures in `screen/`.
- The scripted archive behind the real captures holds 40 near-identical documents with a blank PDF. I judged content from the renders and chrome from the captures.
- I read the Swift files of `application_interface/` that draw a screen, `InterfacePalette.swift`, the `AccentColor` asset, `project.yml`, the presentation types of `application_presentation/` and `library_presentation/`, the exported types of `application_bindings`, and the scene list of `interface_renderer/ScreenRenderer.swift`. I read most files through searches for the calls that matter and not line by line.
- The Mac runs macOS 26.6.2 with Xcode 27.2, whose only macOS SDK is `MacOSX27.2.sdk`. I checked every AppKit, PDFKit, and Quick Look name in this note in that SDK's headers over `ssh mac`, with its availability annotation. This note names nothing that the headers mark as newer than macOS 26.1, and it says where a name is newer than the deployment target.
- `project.yml` sets the deployment target to macOS 14.0. The Mac has no macOS 14 or 15 to run, so only the compiler can check a fallback branch.
- Every SF Symbol named here is in the Mac's `CoreGlyphs.bundle` with a release of macOS 14 or earlier. `text.page` is the one symbol the iPhone uses that needs macOS 15, and this note does not use it.
- The point sizes of the text styles are the output of `NSFont.preferredFont(forTextStyle:)`, run on the Mac.
- The contrast ratios are computed with the WCAG formula from the hex values in `InterfacePalette.swift` and the `AccentColor` asset, against background colours sampled from the captures. The dark backgrounds of the real screen carry the wallpaper's tint, so another wallpaper moves those numbers a little.
- Comparisons with Mail, Notes, Finder, Things, and 1Password are from memory. I did not open them in this session.

## The five decisions

1. **One split view of four native parts.** The sidebar, the list, the reader, and the inspector become the four items of one `NSSplitViewController`, built with the system's own constructors, so the system draws the toolbar's sections, the glass, and the dividers. Every toolbar button the application draws itself goes.
2. **The page is the hero of the reader.** The reader shows the original from under the toolbar to the window's lower edge. The header band goes. Original and Text become a control in the toolbar, and the full title stands once, at the head of the inspector.
3. **Everything says its fact once, in the label colour.** A row drops the summary that repeats its title, a title is not link-blue, and an inspector value is not link-blue. Colour marks a state: blue for a document on its way, orange for what needs a person, green for a folder that collects.
4. **Every action has a menu.** A row, a sidebar entry, and a fact gain context menus, and the main menu holds the same commands under the same names. The application has no context menu today.
5. **Each collector page has one default action, and the first window says what Schublade is.** The confirmation's upload button is the default button, Needs Attention is a list of rows with one way out each, and the connection form becomes a welcome with the application's icon. The application gains an icon, which it lacks today.

Decision 3 reverses one part of what the owner chose on 2026-11-22, the link-blue titles. Section 9 gives the reason. The owner told the implementation to go ahead without waiting, so the units build the label colour; blue titles return by one change of `DocumentRowView` if the owner prefers them.

---

## 1. Critique of the current build

### The window and its toolbar (`screen/library_all_documents_light.png`, `screen/library_dark.png`, `screen/window_minimum_size_light.png`)

- The sidebar and the toolbar's buttons take the glass of macOS 26, and the sidebar shows the wallpaper's tint in `screen/library_screen_light.png`. That part is right and costs the application nothing.
- The divider between the reader and the inspector runs through the toolbar to the window's top edge, and the Share and inspector buttons float beside it. The inspector is an ordinary split item inside a second, nested split view (`LibraryDetailSplitViewController`), so the toolbar does not know it.
- The Sort button sits over the reader, about 320 points from the list it sorts. Nothing tells the toolbar where the list ends.
- The search field is about 320 points wide and takes most of the toolbar above the reader.
- Share, the inspector button, and Back are `NSButton` views with the deprecated `.texturedRounded` bezel inside toolbar items. The system draws glass around them, and the system would draw plain items by itself.
- `MainWindowController` sets a minimum of 900 by 560 points, as the design says. The real minimum is 1,102 by 580, because the nested split view's minimums add up and its inspector never collapses when the window narrows. `screen/window_minimum_size_light.png` shows the inspector still open at that width with a title cut to "Haftpflichtversicherung R…".

### The sidebar (`library_document_pdf_light.png`, `screen/library_all_documents_light.png`)

- A count stands directly after its name, "All Documents 1,508", and the counts form no column. A native source list sets the count at the trailing edge.
- Every collecting folder carries a checkmark. A mark on every row says nothing, and a row without a mark could say "collecting".
- The symbols are tinted with `InterfacePalette.archive`, `attention`, and `collector`. On the sidebar's `#F9F9FA` they measure 2.92:1, 2.59:1, and 2.50:1, below the 3:1 that a symbol with meaning needs.
- In `library_archive_outdated_light.png` the status line reads "Archive update required" in `InterfacePalette.attention` as text, 2.59:1.
- "Add Folder…" is a command in a list of places. It can stay, because a first-time person finds it there, but it should not look like a destination.

### The document list (`library_document_pdf_light.png`, `screen/library_all_documents_light.png`)

- Every title is link-blue and semibold. A list of forty blue lines reads as forty links, and the one blue line that carries a state, "Classifying document", looks like a title. Mail, Notes, and Finder draw a list's primary text in the label colour, and the iPhone application now does too.
- The third line repeats the title. "Electricity Annual Sta…" stands over "Annual electricity statement for 2026 sh…".
- The date shares the title's line, so the title has about 60 % of the row. "Electricity Annual Sta…" and "Haftpflichtversicheru…" are cut while the row has room for a second line.
- The Arriving row shows a file name, a blank page icon, and an empty second line. It is the Mac's sign that the folders work, and it is the least designed row.
- The stage text is `InterfacePalette.archive` on white, 3.08:1, and 2.44:1 on the selection fill. Body text needs 4.5:1.
- The row has no context menu. A Control-click on a document does nothing.
- The selection, a light blue fill with a blue edge, is good. It keeps the picture and the amount readable, and it is the list's one trait from the website.

### The empty archive and no selection (`library_empty_light.png`, `screen/library_empty_selection_light.png`)

- The empty archive shows three panes. Two of them say "No Document Selected" while no document exists to select.
- With documents and no selection, the reader and the inspector both say "No Document Selected".
- The empty list shows no picture, and its one button is a small grey push button.
- The application opens with no selection every time. It remembers the window's frame and the collapsed sections, and it forgets the scope and the document a person was reading.

### Search (`library_search_text_light.png`, `screen/library_search_light.png`)

- The excerpt "…die Haftpflichtversicherung und Abschl…" does not mark the word that matched.
- The row under "Matches in Text" opens the original at its top. Nothing leads to the match.
- The placeholder reads "Search" in every scope, so a search inside Invoice looks like a search of everything until a person reads the window's title.
- The foot of the list, "Search All Documents" over "Searching the text of 1,200 of 1,508 documents", is right.

### The reader (`library_document_pdf_light.png`, `library_search_text_light.png`, `screen/library_text_tab_light.png`)

- A band with the title, a line of facts, and the Original and Text control sits between the toolbar and the page. It is a second toolbar, and it holds the title a third time, after the row and before the page's own letterhead.
- The selected segment is filled with the accent colour. It is the most saturated thing in the window, and it marks a view switch.
- The page starts under an opaque band and never passes under the toolbar's glass.
- The Text tab shows the Markdown's own marks. `library_search_text_light.png` shows a heading that begins with "# Stadtwerke Talbrück GmbH" in the body font, and lines that run the reader's full width.
- "The Original Is Not on This Mac" in `library_offline_missing_original_light.png` has the right words and no picture.

### The inspector (`library_document_pdf_light.png`, `library_document_image_light.png`)

- The headings "DETAILS", "TAGS", "SUMMARY", and "FILE" are blue, bold, and in capitals with letter spacing. They are the website's panel bars at a smaller size, which direction A rejected.
- Sender, Category, and Person are link-blue, and so is every tag. With the titles, a third of the window's text is blue.
- The facts a person opens an invoice for, Amount, Due, and IBAN, come after three filing facts.
- A value copies through a control that shows only under the pointer. Nothing announces it, and VoiceOver cannot hover.
- The inspector does not state the title, so with the header band gone no place would hold the whole title. Section 5 moves it here.
- "Open in Browser" is a bare button under "Added". Nothing says why a person would go to the browser.

### The folder pages (`folder_collecting_light.png`, `folder_confirmation_light.png`, `folder_surveying_light.png`)

- The header draws a green `folder.fill` symbol and a raw path, "/Users/owner/Paperwork". Finder shows the folder's own icon and a path a person can click.
- "Remove Folder…" stands at the top right with the weight of a main action.
- "Collecting" is semibold text in `InterfacePalette.collector`, 2.63:1 on white. "Awaiting your decision" is `attention`, 2.73:1.
- The confirmation's two buttons are both grey. "Upload 48 files and start collecting" is the one decision of the collector, and the Return key does nothing.
- The buttons read "Remove folder" and "Upload 48 files and start collecting". A Mac button's title takes title-style capitals.
- The sentence that Schublade never changes, moves, or deletes a file is what a person needs before the decision. It stands under the buttons in small grey text.
- In "Recently Uploaded from This Mac" the file names are link-blue and the states are coloured words: "Processing" at 3.08:1, "Archived" at 2.63:1, and "Failed" in the system's red at 3.55:1.
- The toolbar still shows Sort, the search field, Share, and the inspector button on a page where none of them does anything.

### Needs Attention (`needs_attention_light.png`)

- The items are sentences behind bullets, orange for one and red for two, and no legend says what the two colours mean.
- The ways out are small grey buttons set after the sentences at three different positions.
- The page's heading repeats the window's title one line below it.

### The connection form (`connection_form_light.png`, `screen/connection_form_light.png`, `screen/connection_form_dark.png`)

- It is the first window a person ever sees, and it is a login form in a window of 1,340 by 820 points: a title, a grey sentence, two fields, a button. It shows no icon and does not say what Schublade does.
- The window keeps a title bar with "Schublade" and a hairline over an empty page.
- "API token from Settings" does not say that the Settings are the archive's, in the browser.
- The offscreen render `connection_form_dark.png` draws white text on a white page. The real capture is correct, so the renderer's window does not follow the appearance. The unit that touches the form repairs the renderer.

### Settings (`screen/settings_general_light.png`, `screen/settings_archive_light.png`, `screen/settings_storage_light.png`)

- The three toolbar tabs are the Mac's convention and should stay.
- Archive shows a host and a sentence. It does not show whether the copy is current, which the iPhone's Settings shows.
- The application sets no version, so the About panel shows none, and the bundle has no icon to show there.

### The menu bar item (`status_item_glyphs_light.png`, `status_item_menu.txt`, `screen/menu_bar_menu.png`)

- The glyphs are the best-drawn part of the application.
- The menu's "Recently Added" is a disabled item used as a heading. `NSMenuItem.sectionHeader(title:)` exists for it.
- A document is its title alone. Five lines of "Haftpflichtversicherung Rechnung" show that a title does not always tell two documents apart.
- An upload shows twice, as "Uploading 1 file" and "Uploading Tax assessment 2025.pdf".
- macOS 26 draws symbols beside Settings… and Quit. The application's own items have none, so the titles form two columns.

### The main menu (`screen/main_menu_file.png`, `screen/main_menu_view.png`)

- View holds "Show Tab Bar" and "Show All Tabs". The application has one window, and the window never set `tabbingMode`.
- "Toggle Sidebar" and "Toggle Inspector" should read "Show Sidebar" or "Hide Sidebar", and the same for the inspector.
- "Open Original" and "Quick Look" show no key. Finder shows Command-O and Command-Y.
- Edit has no Undo and no Find Next. The application has no Help menu, so a person cannot search the menus.

### The icon

- `application/Assets.xcassets` holds `AccentColor` and nothing else, and `project.yml` names no icon. The Dock in `screen/library_screen_light.png` shows the generic application icon. `application/application_icon.svg` is the drawing, and nothing renders it.

---

## 2. Information architecture

### One window, four parts

```text
┌──────────┬───────────────────┬──────────────────────────────────┬──────────────┐
│ ● ● ●  ▯ │ All Documents  ⇅  │      ( Original | Text )   ⇪  🔍  │            ▯ │  toolbar
│          │ 1,508 documents   │                                  │              │
│ Library  ├───────────────────┤                                  │ Electricity  │
│  All…    │ Arriving          │                                  │ Annual       │
│  Recent… │ ▢ Meldebeschein…  │          the original,           │ Statement    │
│ People   │ September 2026    │      under the toolbar's glass   │ 2026         │
│ Categor… │ ▢ Electricity     │                                  │ Annual elec… │
│ Tags     │   Annual State…   │                                  │              │
│ Folders… │   Stadtwerke · 22 │                                  │ Date         │
│          │        1,234.50 € │                                  │ 22 Sep 2026  │
│ ✓ Up to… │ ▢ Supermarket R…  │                                  │ Amount       │
└──────────┴───────────────────┴──────────────────────────────────┴──────────────┘
  sidebar    content list        reader                             inspector
```

`LibraryWorkspaceViewController` becomes one `NSSplitViewController` with four items.

| Part | Constructor | Thickness | Collapses |
| --- | --- | --- | --- |
| Sidebar | `NSSplitViewItem(sidebarWithViewController:)` | 214 to 280 | by its toolbar button and when the window narrows |
| List | `NSSplitViewItem(contentListWithViewController:)` | 270 to 440 | on a page only |
| Reader | `NSSplitViewItem(viewController:)` | at least 360 | never |
| Inspector | `NSSplitViewItem(inspectorWithViewController:)` | 220 to 320 | first when the window narrows, `canCollapseFromWindowResize = true` |

- The window's minimum becomes true: 900 by 560 points, with the inspector collapsed below about 1,070, the sum of the four minimums.
- A page that is not about documents, a folder, Needs Attention, or the empty archive, collapses the list and the inspector and shows in the reader's place. The sidebar stays.
- **This is the one part to try before keeping.** Build the flat split view first and switch between All Documents and a folder page twenty times. If the dividers lose their place or the list flashes, keep the container that swaps the page for the three panes, and build only the inspector with `inspectorWithViewController:` in the inner split view. The toolbar then tracks the inner split view's dividers through `NSTrackingSeparatorToolbarItem`.
- **What unit M1 found.** The flat split view stayed: twenty switches in the end-to-end test left every divider where it was. `canCollapseFromWindowResize` alone kept the window at about 1,073 points, the sum of the four minimums, so the window's delegate collapses the inspector in `windowWillResize(_:to:)`, and in `windowDidResize(_:)` for a frame set by tiling or Accessibility, which then takes a second request to reach 900 points. A frame minimum of 560 points became a content minimum of 580, so the window sets `contentMinSize`. `NSSplitViewController` raises an exception for a split view of its own subclass in a titled window, so the window's controller holds the Quick Look panel's control.

### The toolbar

`toolbarStyle` stays `.unified`. `window.tabbingMode = .disallowed`. The items, in order:

| Item | Kind | Notes |
| --- | --- | --- |
| Sidebar | `.toggleSidebar` | the system's |
| Back | `NSToolbarItem`, `chevron.backward`, `isNavigational = true` | only while a sender's documents show |
| | `.sidebarTrackingSeparator` | |
| Sort | `NSMenuToolbarItem`, `arrow.up.arrow.down` | over the list's trailing edge, beside the title and the count |
| | `NSTrackingSeparatorToolbarItem` for the divider between the list and the reader | |
| Original and Text | `NSToolbarItemGroup` with the titles "Original" and "Text", `selectionMode = .selectOne` | over the reader |
| | `.flexibleSpace` | |
| Share | `NSSharingServicePickerToolbarItem` | its delegate gives the original's named copy |
| Search | `NSSearchToolbarItem`, `preferredWidthForSearchField = 240` | Command-F |
| | `.inspectorTrackingSeparator` | macOS 14 |
| | `.flexibleSpace` | |
| Inspector | `.toggleInspector` | macOS 14, the system's, Option-Command-I |

- Every item is a plain `NSToolbarItem` with an image, a label, a target, and an action. No item holds an `NSButton`.
- No item is `.prominent`. The library has no main action, and a tinted button would claim one.
- On a page, Sort, the group, Share, and the inspector item leave the toolbar the way Back does today, by `removeItem(at:)` and `insertItem(withItemIdentifier:at:)`. `NSToolbarItem.isHidden` needs macOS 15.
- Measured by unit M1 on macOS 26: the search field takes about 327 points while the toolbar has room and 238 at the window's minimum, whatever `preferredWidthForSearchField` says. The tracking separator between the list and the reader draws its line through the toolbar, and the inspector's item takes the full height, so no line divides the reader's toolbar from the inspector's. Share hands over the named copy once the reader holds the original, and nothing before.
- The window's title is the scope, "All Documents" or "Invoice", and its subtitle is the count, as today.

### Where things live

| Thing | Place |
| --- | --- |
| What is on its way | The "Arriving" section on top of the list, and the Arriving entry of the sidebar |
| What needs a person | Needs Attention in the sidebar, the status line, the menu bar glyph, and two notifications |
| The scope | The sidebar's selection, the window's title, and the search field's placeholder |
| A document's actions | The row's context menu, the File menu, and the toolbar's Share |
| A folder's actions | The sidebar entry's context menu, the File menu, and the More menu of the folder's page |
| Synchronize | The status line, and View > Synchronize Now with Command-R |
| The token, storage, start at login | The Settings window |
| The version | The About panel |
| Revising, deleting, retrying | "Open in Browser" at the foot of the inspector, with a sentence that says so |

### The main menu

| Menu | Items |
| --- | --- |
| Schublade | About Schublade. Settings… (Command-Comma). Hide, Hide Others, Show All. Quit |
| File | Add Folder… (Shift-Command-O). Remove Folder…, while a folder's page shows. Open Original (Command-O, and Return in the list). Quick Look (Command-Y, and Space in the list). Share, the submenu of `NSSharingServicePicker.standardShareMenuItem`. Export Original… (Shift-Command-E). Open in Browser (Option-Command-B). Close Window (Command-W) |
| Edit | Undo, Redo. Cut, Copy, Paste, Select All. A Find submenu with Search (Command-F), Find Next (Command-G), and Find Previous (Shift-Command-G) |
| View | Original (Command-1) and Text (Command-2), with a checkmark on the shown one. Sort By, with a checkmark. Show Sidebar or Hide Sidebar (Control-Command-S) through `toggleSidebar:`. Show Inspector or Hide Inspector (Option-Command-I) through `toggleInspector:`. Synchronize Now (Command-R). Enter Full Screen |
| Window | Minimize, Zoom. Library (Command-0), which shows the main window. Bring All to Front |
| Help | An empty menu set as `NSApp.helpMenu`, so the system adds its search of the menus |

- Each item of the application's own takes an SF Symbol as its `image`, because macOS 26 draws symbols beside the system's items in the captures: `folder.badge.plus`, `arrow.up.forward.app`, `eye`, `square.and.arrow.up`, `square.and.arrow.down`, `safari`, `arrow.clockwise`.
- I expect AppKit to switch the titles of the two `toggle` items between Show and Hide by itself. That is from memory. If it does not, `validateMenuItem(_:)` sets them.
- The Go menu of Finder and Mail is not added. Tab reaches the sidebar, and the scopes are a list the household makes.

---

## 3. The sidebar and its status line

- `NSOutlineView` with `style = .sourceList`, as today.
- **Counts form a column.** The title's hugging priority drops below the count's, so the count sits at the trailing edge in `subheadline`, monospaced digits, `secondaryLabelColor`.
- **Symbols.** `tray.full`, `clock`, `arrow.down.doc`, `exclamationmark.triangle`, `house`, `person`, `folder`, `tag`, as today. Their colours are the three text-safe tokens of section 9: blue for the library's entries, orange for Needs Attention, green for the folders.
- **A folder's accessory says only what is unusual.** A collecting folder shows nothing. A folder under survey shows an `NSProgressIndicator` with `style = .spinning` and `controlSize = .small`. A folder that awaits its decision shows `exclamationmark.circle.fill` in orange. A folder that cannot be read shows `questionmark.folder` in orange. Each accessory has an accessibility description, such as "Awaits your decision".
- **"Add Folder…"** stays the last row of its section, with `plus` and its title in `secondaryLabelColor`, so it reads as a command.
- **Context menus**, through `outlineView.menu` and its delegate. A folder: Show in Finder (`folder`), Remove Folder… (`minus.circle`). The section header of the folders: Add Folder…. A library entry has none.
- **The status line** keeps its one line and its precedence. From macOS 26 it is an `NSSplitViewItemAccessoryViewController` in the sidebar item's `bottomAlignedAccessoryViewControllers`, so the list scrolls under it with the system's edge effect. Before macOS 26 it stays the pinned view of today. That is one of the two version checks of this direction.
- Its text is `subheadline` in `secondaryLabelColor`, and in the orange token for a refused token or an outdated archive. A click synchronizes, or opens the replace form when the token is refused, as today. Its tooltip names which.

## 4. The document list

### Row anatomy

One fixed row height stays, because the table places 50,000 rows without measuring any. The row computes its height once from the fonts' line heights. It is 68 points with the system's sizes.

```text
12 ┌─────┐ 10  Title in headline, up to two lines while a person browses
   │40×52│     Sender · 22 Sep                        1,234.50 EUR
   └─────┘     Third line, only when it adds something            12
```

| Element | Style | Colour | Lines |
| --- | --- | --- | --- |
| Picture | 40 by 52 points, `cornerRadius` 4, a 0.5-point edge in `separatorColor`, cut from the page's top edge | on `textBackgroundColor` | |
| Title | `headline` | `labelColor` | 2 while browsing, 1 when a third line shows |
| Sender and date | `subheadline` | `secondaryLabelColor` | 1, the sender truncates and the date does not |
| Amount | `subheadline`, monospaced digits, medium weight | `labelColor` | 1, trailing on the sender's line |
| Third line | `subheadline` | by state: `secondaryLabelColor`, blue, orange | 1 |

- **The third line shows only when it adds something.** An archived document has none while a person browses, so the summary that repeats the title goes and the title gains its second line. A document in ingestion shows its stage in blue. A failed document shows its failure in orange. In a search the row shows the excerpt or the summary, as today.
- **Short dates under a month.** Under a `ListingHeading.period` heading the date is "22 Sep", from `DocumentFormatting.dayAndMonth`, which the iPhone added to `library_presentation/`. Everywhere else it is the full date.
- **A document in ingestion** shows its picture as soon as `contentKnown` is true, and a small spinner at the trailing edge of its title's line. A failed document shows `exclamationmark.circle.fill` in orange there.
- **Without a picture** the row shows `doc.text` in `tertiaryLabelColor` on `quaternarySystemFillColor`, as the iPhone's row does.
- **When a row changes state**, from ingestion to archived, the cell's content cross-dissolves in 0.25 s. The listing's difference already revises the row in place.
- **The selection** stays `DocumentListRowView`'s fill with its leading edge.
- **Month headings** stay floating group rows in `subheadline`, semibold, `secondaryLabelColor`.

### What the Mac does not take from the iPhone's arrival row

The iPhone shows a letter from Save to its title with a ring, because a person just sent it and watches. The Mac's collector sends files while nobody watches, a backlog can hold 930 of them, and a `Receipt` carries no fraction sent. So the Mac shows no row before the archive holds the document. An upload in flight shows in the status line and the menu bar glyph, and the document appears under Arriving with its picture once the archive has its bytes.

### Context menu

`tableView.menu` with an `NSMenuDelegate` that builds the menu for `clickedRow`.

| Item | Symbol | Does |
| --- | --- | --- |
| Open Original | `arrow.up.forward.app` | as Return |
| Quick Look | `eye` | as Space |
| Share | `square.and.arrow.up` | `NSSharingServicePicker(items:).standardShareMenuItem` |
| Copy | `doc.on.doc` | the file, as Command-C |
| Export Original… | `square.and.arrow.down` | |
| More from, and the sender's name | `building.2` | shows the sender's documents, as the inspector's row does |
| Open in Browser | `safari` | |

`WorkspaceDocumentActions` already holds every action. A document in ingestion or failed offers only what applies to it.

### Empty and loading states

AppKit has no content-unavailable view. One `EmptyStateView` draws all of them: an image at 44 points in `tertiaryLabelColor`, a title in `title2` semibold, a detail in `body` in `secondaryLabelColor` at most 360 points wide, and at most one button. `DocumentListEmptyView`, `ReaderPlaceholderView`, `StatusMessageViewController`, and `WorkspaceNoticeViewController` become uses of it.

| State | Where | Image | Title | Detail | Button |
| --- | --- | --- | --- | --- | --- |
| Empty archive | a page in place of the three panes | `DrawerGlyph`'s empty drawer | No Documents Yet | Add a folder, and Schublade archives the PDFs and pictures in it. Documents from your iPhone and the browser appear here too. | Add Folder…, the default button |
| First copy filling | the list | a spinner | Loading Documents… | the status line's text | none |
| Empty scope | the list | `tray` | `EmptyListPresentation`'s title | its detail | none |
| No result | the list | `magnifyingglass` | `EmptyListPresentation`'s title | its detail | Search All Documents, where it applies |
| Nothing selected | the reader only | `doc.text` | No Document Selected | none | none |
| Archive outdated | a page | `exclamationmark.triangle` | Update Required | Update your archive to use the library. | none |

- The inspector shows nothing while no document is selected. Its second "No Document Selected" goes.
- **The window reopens on what it showed.** `LibraryNavigationState`'s scope and the selected document go to `UserDefaults` when they change, and the next launch selects them again when the copy still holds them.

### Search

- One `NSSearchToolbarItem`. Command-F focuses it and Escape clears it, as today.
- **The placeholder names the scope.** "Search All Documents", "Search Invoice", "Search Jonas Becker". The sidebar shows the scope beside the results, so the Mac needs no token in the field. AppKit's `NSSearchField` has neither tokens nor suggestions in this SDK.
- **The excerpt marks what matched.** In a row under "Matches in Text", each occurrence of a search term is `labelColor` at semibold weight, and the rest stays `secondaryLabelColor`. The matching is the iPhone's `LibrarySearch.matchedRanges`, which unit S1 moves to `library_presentation/`.
- **A text match opens on the match.** Selecting a row under "Matches in Text" marks the words in the PDF, as `SearchWordHighlighting` does today, and scrolls to the first with `pdfView.go(to:)`. When the original has nothing to mark, a scan or a picture, the reader shows the Text tab with the first match scrolled into view and shown by `showFindIndicator(for:)`.
- **Find Next and Find Previous** step through the marked matches of the shown tab.
- The 250 ms pause, the two sections, and the foot of the list stay.

## 5. The reader and the inspector

### The original

- `ReaderHeaderView` goes. The reader's view is the `PDFView` or the `ImageReaderView` alone, from the window's top edge to its bottom, so the page scrolls under the toolbar. From memory, macOS 26 then draws its scroll edge effect under the toolbar's items. Only the real screen shows it. The fix of 2026-11-22 for a header under the toolbar no longer applies, because no header remains.
- `PDFView` keeps `autoScales = true`, `displayMode = .singlePageContinuous`, and `displaysPageBreaks = true`, on `InterfacePalette.readerBackdrop`.
- A page and a picture stay white in the dark, because they are paper.
- A double click on the page opens the original in its default application, as Return does in the list.
- The states "Loading Original…", "The Original Is Not on This Mac" with `wifi.slash` and Try Again, and the email not yet printed use `EmptyStateView`.

### The text

The Text tab becomes a page to read. Unit S1 moves the iPhone's `TextParagraph.paragraphs(of:)` to `library_presentation/`, and the Mac builds an `NSAttributedString` from the paragraphs.

- Body text in `body`, `labelColor`, with `lineHeightMultiple` 1.2 and `paragraphSpacing` 8.
- The text column is at most 680 points wide and centred. `textContainerInset` gives 24 points on every side.
- A line "## Page 2" is a page mark: `subheadline`, semibold, `secondaryLabelColor`, with 24 points above it. Any other heading is `headline`. The marks of the Markdown do not show.
- A table row is drawn in `NSFont.monospacedSystemFont` at 11 points and does not wrap. A separator row of dashes is dropped.
- A search marks every match with `NSColor.findHighlightColor` as a background attribute.
- The text stays selectable, and Command-C copies the selection.

### The inspector

The inspector is the place of the facts. It is a scroll view over one stack, 16 points from each edge.

1. **Head.** The title in `title3`, semibold, as many lines as it needs. Under it the summary in `body`, `secondaryLabelColor`. Under that one line in `subheadline`, `secondaryLabelColor`: "2 pages · PDF".
2. **Facts**, without a heading: every `InspectorDetailRow` that has no `linkedScope`, in the presentation's order. Date, Amount, Due, IBAN, Invoice, Customer, Policy, and the others.
3. **Filed Under**: every row with a `linkedScope`. Sender, Category, Person.
4. **Tags**, while the document has any.
5. **File**: Size and Added. Then "Open in Browser", a push button with `safari`, over one sentence in `footnote`, `secondaryLabelColor`: "Edit the details, retry, or delete this document in your archive in the browser."

Rows:

- A label in `subheadline`, `secondaryLabelColor`, over its value in `body`, `labelColor`. Every value uses monospaced digits, as the iPhone's sheet does, because the presentation does not say which value is an amount.
- A section heading is `subheadline`, semibold, `secondaryLabelColor`, in sentence case. The blue capitals go.
- **A click copies a fact.** A row of Facts is one button the width of the inspector. Under the pointer it shows a rounded fill in `quaternarySystemFillColor` and `doc.on.doc` at its trailing edge. A click writes `copyValue` to the pasteboard, and for one second the value reads "Copied" in blue beside `checkmark`. VoiceOver hears "Copied". The row has the button role, takes the keyboard focus, and Space copies. Its context menu holds Copy. 1Password's fields work this way, from memory.
- The value is no longer selectable text. A person who wants half an IBAN pastes it and cuts.
- **A row of Filed Under leads somewhere.** Its value is `labelColor`, and `chevron.right` in `tertiaryLabelColor` stands at its trailing edge, always shown. A click lists the documents of the sender, category, or person, as today. The two trailing symbols tell a person what a click does before the click.
- **A tag** is a chip with `quaternarySystemFillColor` as its fill, no border, and its name in `labelColor` at `subheadline`. A click lists the tag's documents. `chipFill` and `chipBorder` leave the palette.
- The link colour goes from every value.

With the inspector hidden, the window states the full title nowhere but in the row's tooltip. A person who hid the inspector chose the page. Option-Command-I brings the facts back.

## 6. The collector's pages

A page stays a centred column of at most 680 points, with every preferred size below priority 500, as `PageColumnView` has it.

### A folder's page

```text
 ┌────┐  Paperwork                                          ( ⋯ )
 │icon│  Macintosh HD › Users › owner › Paperwork
 └────┘
 ✓ Collecting
 New PDF, JPEG, PNG, and WebP files upload automatically.
```

- **The icon** is the folder's own, `NSWorkspace.shared.icon(forFile:)` at 48 points, so Downloads looks as it does in Finder.
- **The name** is `title1`, bold.
- **The path** is an `NSPathControl` with `pathStyle = .standard`, not editable, on a clear background. A double click on a part shows it in Finder.
- **More** is a pull-down button with `ellipsis.circle` at the header's trailing edge: Show in Finder, Remove Folder…. The removal keeps its alert.
- **The state** is one line: `checkmark.circle.fill` and "Collecting" in green, `exclamationmark.circle.fill` and "Awaiting Your Decision" in orange, or a small spinner and "Surveying" in `secondaryLabelColor`. The detail sentence follows in `body`.

### The confirmation

- The heading "Collect from Paperwork?" in `title2`, bold.
- Directly under it, in `body`, the sentence that stands under the buttons today: "Schublade reads the PDF, JPEG, PNG, and WebP files in this folder and its subfolders. It never changes, moves, or deletes your files, and removing the folder keeps what Schublade received."
- The two groups, "The files already there" and "From now on", keep `BacklogConfirmationWording`'s sentences. The skipped reasons stay a grid with their counts at the trailing edge in monospaced digits.
- The buttons stand at the trailing edge under the groups. "Upload 48 Files and Start Collecting" is the default button, with `keyEquivalent = "\r"` and `controlSize = .large`. "Remove Folder" stands at its leading side at the same size.
- `BacklogConfirmationWording.uploadLabel` and `removeLabel` take title-style capitals, and their tests follow.

### Recently uploaded

One group, "Recently Uploaded from This Mac", as rows of a list.

| Outcome | Leading | Name | Trailing |
| --- | --- | --- | --- |
| Processing | a small spinner | the file name in `labelColor` | "Processing" and the time, `secondaryLabelColor` |
| Archived | `checkmark.circle.fill` in green | the same | the time |
| Failed | `exclamationmark.circle.fill` in orange | the same | "Failed" in orange, and the time |

A click on a row selects the document in the library, as today. The times use monospaced digits.

### Needs Attention

- The page's own heading goes. The window's title says "Needs Attention".
- Each group, "On This Mac" and "In the Archive", is a box of rows with hairlines between them, as a pane of System Settings has them.
- A row holds a symbol in orange, its sentence in `body`, and at most one push button at the trailing edge.

| Item | Symbol | Button |
| --- | --- | --- |
| A folder awaits its decision | `folder` | Review… |
| A folder cannot be read | `questionmark.folder` | Show in Finder |
| The archive refused the token | `key` | Replace Token… |
| The archive refused a file | `doc.questionmark` | none |
| Documents the archive could not read | `doc.text` | Show Failed Documents |

- One colour marks all of them. The red bullets go, because the page has one meaning, a thing that waits for a person.
- The sentence "Each one can be retried or deleted in the browser." stays under the last row in `footnote`.

## 7. First run and Settings

### The welcome

`ConnectionFormViewController` becomes the welcome. While it shows, the window has no toolbar, `titleVisibility = .hidden`, and `titlebarAppearsTransparent = true`.

```text
                    ┌──────┐
                    │ icon │  96 pt
                    └──────┘
              Connect Your Archive                 title1, bold
     Schublade keeps every document of your        body, secondaryLabelColor
   archive at hand on this Mac, even offline,
   and archives the papers in the folders you add.

        Address  [ https://archive.example.org  ]
          Token  [ ••••••••••••••••••••••••••••  ]
                 In your archive's Settings in the browser,
                 issue a token of the kind "Schublade app".
                                          ( Connect )
```

- The icon is `NSApp.applicationIconImage`, so the screen needs no picture of its own once the application has an icon.
- The form is an `NSGridView` of 420 points with its labels at the trailing edge of the first column, the Mac's form layout. The token field is an `NSSecureTextField`.
- Connect is the default button at `controlSize = .large`, at the form's trailing edge. While it connects, it shows a small spinner at its leading side and both fields are disabled, as today.
- A refusal takes the place of the footnote: `exclamationmark.circle.fill` in the system's red and the sentence in `labelColor`. The system's red as text measures 3.55:1 on white, so the symbol carries the colour and the sentence stays black. VoiceOver hears the sentence through `NSAccessibility.post(element:notification:userInfo:)` with `.announcementRequested`.
- The replace form is the same view without the icon and the sentence, titled "Replace Token", with the address filled in, the focus in the token field, and Cancel beside Connect.
- A start failure shows through `EmptyStateView` with `exclamationmark.triangle` and the sentences of `StartFailureWording`.

### Settings

The three toolbar tabs stay, with `gearshape`, `archivebox`, and `internaldrive`.

- **General.** Open Schublade at Login and Show Schublade in the Menu Bar, as today.
- **Archive.** The host in `headline`. Under it the status line with its symbol, "Up to date · 21:56", as the iPhone's Settings shows it. Then the sentence of what the token permits, and Replace Token… and Open Archive in Browser.
- **Storage.** The sentence of the space taken stands first. The limit and Remove Downloaded Originals follow, as today.
- Each pane is an `NSGridView` with 20 points of margin, 480 points wide.

### About

The Mac's place for the icon, the name, and the version is the About panel. "About Schublade" stays `orderFrontStandardAboutPanel(_:)`. `project.yml` gains `CFBundleShortVersionString` and `CFBundleVersion`, which the application lacks today, and the bundle gains its icon. The iPhone's footer in Settings has no place on the Mac.

## 8. The menu bar item, Quick Look, dragging, and sharing

### The menu

```text
Up to date · 14:02                                 disabled, the status line
Uploading Tax assessment 2025.pdf                  one line, or "Uploading 3 files"
──────────────
⚠ Paperwork waits for your decision.               each attention item, opens its page
──────────────
Recently Added                                     NSMenuItem.sectionHeader(title:)
 ▢ Electricity Annual Statement 2026
   Stadtwerke Talbrück GmbH · 22 Sep
 ▢ Supermarket Receipt
   Frischemarkt · 18 Sep
──────────────
Open Schublade
Add Folder…
Settings…
──────────────
Quit Schublade
```

- A document's item gains `subtitle`, the sender and the short date. `NSMenuItem.subtitle` needs macOS 14.4, above the deployment target of 14.0, so it is the second version check. Its `image` is `doc.text`.
- An attention item takes `exclamationmark.triangle.fill` as its image. Open Schublade takes `macwindow` and Add Folder… takes `folder.badge.plus`, so the titles form one column with the system's symbols.
- The glyphs, their precedence, and the animation stay as they are.
- The button's accessibility title says the state, such as "Schublade, up to date".

### Quick Look

- Space and Command-Y show the panel, as today. `LibraryDetailSplitViewController` keeps the panel's control.
- `QuickLookCoordinator` answers `previewPanel(_:sourceFrameOnScreenFor:)` with the frame of the row's picture and `previewPanel(_:transitionImageFor:contentRect:)` with the picture, so the panel grows out of the row and returns to it. It answers neither today.

### Dragging and sharing

- A row drags as an `NSFilePromiseProvider` under the suggested name, as today.
- Share in the toolbar, the File menu, and the context menu hand over the same named copy.
- The list offers no swipe actions. A Mac list has its context menu.

---

## 9. The visual language

### Tint and colour

Native first, with the website's three colours. Today each colour has one value that passes as a fill and fails as text. The Mac uses each colour mostly for text and small symbols, so each token takes a value that passes 4.5:1 on every background the window has, and nobody must remember which use is safe.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `AccentColor` | `#0B5CBF` | `#3A8EE6` | Unchanged. The system's controls, the default buttons, the selected segment |
| `InterfacePalette.archive` | `#0B57B0` | `#7DB8FF` | Blue text and symbols: the library's entries, a document's stage, "Copied". These are today's `link` values |
| `InterfacePalette.attention` | `#9A5200` | `#F5A03C` | Orange text and symbols: Needs Attention, a failure, a refusal |
| `InterfacePalette.collector` | `#3F7000` | `#9DCB45` | Green text and symbols: the folders, "Collecting", an archived upload |
| `selectionFill`, `selectionEdge`, and the inactive pair | unchanged | unchanged | The list's selection |
| `readerBackdrop` | unchanged | unchanged | Behind a page |
| `link`, `chipFill`, `chipBorder` | | | Removed |

Measured ratios, with the backgrounds sampled from the captures: white `#FFFFFF`, the light sidebar `#F9F9FA`, the light selection fill `#D6E7FB`, the dark content `#23292C`, and the dark selection fill `#1F3A5C`.

| Colour | On white | On the sidebar | On the selection fill | Dark, on the content | Dark, on the selection fill |
| --- | --- | --- | --- | --- | --- |
| `archive` today, `#4A97E3` | 3.08 | 2.92 | 2.44 | | |
| `attention` today, `#E5850F` | 2.73 | 2.59 | 2.17 | | |
| `collector` today, `#7FAE24` | 2.63 | 2.50 | 2.09 | | |
| The system's red, `#FF3B30` | 3.55 | 3.37 | 2.82 | | |
| `archive` new | 6.99 | 6.64 | 5.55 | 7.14 | 5.60 |
| `attention` new | 5.86 | 5.57 | 4.66 | 7.00 | 5.49 |
| `collector` new | 5.95 | 5.66 | 4.73 | 7.76 | 6.08 |

- The iPhone's `attentionText` is `#A85A00`. On the Mac's selection fill it measures 4.04:1, so the Mac's orange is one step darker.
- The dark accent `#3A8EE6` as text measures 4.35:1 on the dark content and 3.41:1 on the dark selection fill. Text that carries the blue therefore uses `archive` and never the accent.
- A white title on the accent measures 6.37:1 in the light and 3.39:1 in the dark. The system draws the default button's title. Its own dark blue `#0A84FF` gives 3.65:1, so the dark default button is as legible as the system's.
- Everything else is a system colour: `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `textBackgroundColor`, `quaternarySystemFillColor`, `separatorColor`, `findHighlightColor`. No view holds a colour literal.
- A layer keeps the colour it was given, so a view that colours a layer sets the colour again in `viewDidChangeEffectiveAppearance`, as `DocumentRowView` does.

### Why titles are not link-blue

The owner's choice of 2026-11-22 lists link-blue titles as one of the website's traits. I recommend the label colour, for three reasons. Forty blue titles leave blue no meaning, and the one blue line that says "Classifying document" disappears among them. Mail, Notes, and Finder draw a list's primary text in the label colour, and direction A is native first. The iPhone application settled the label colour this week, and the two applications should read alike. The selection with its blue edge, the blue symbols, and the tint of every control keep the website's blue in the window. If the owner keeps blue titles, `archive` passes at 6.99:1 and nothing else in this direction changes.

### Typography

Every label takes `NSFont.preferredFont(forTextStyle:)`. On this Mac the styles measure: `title1` 22, `title2` 17, `title3` 15, `headline` 13 bold, `body` 13, `callout` 12, `subheadline` 11, and `footnote` 10 points. The fixed sizes `NSFont.systemFontSize` and `smallSystemFontSize` leave the views. Three rules apply everywhere.

- Numbers that a person compares or copies use monospaced digits: amounts, IBANs, counts, dates in a column.
- No custom font.
- `footnote` is 10 points on the Mac, so it is for one sentence under a control and never for a row's content.

### Text size

macOS has no Dynamic Type. A table's row height and the inspector's stack follow the fonts' metrics and hold no literal height, so a larger text size from the system enlarges them. Whether macOS 26 scales text styles in a third-party application is not something I checked.

### Liquid Glass and macOS 14 and 15

- The toolbar, the sidebar, the menus, and the Quick Look panel take the glass from the system on macOS 26. The application creates no `NSGlassEffectView` and no `NSVisualEffectView`, and sets no background on a toolbar item.
- Content passes under the toolbar: the list, the page, and the text. No opaque band stands between the toolbar and the content.
- Glass is for the layer of controls. Rows, pictures, boxes, and the buttons of a page are content and take `.push` bezels.
- The SDK marks `NSGlassEffectView.effectIsInteractive` and `NSStatusItem.expandedInterfaceDelegate` as macOS 27. This direction uses neither.
- The version checks are two: the status line as a bottom accessory from macOS 26, and a menu item's `subtitle` from macOS 14.4. On macOS 14 and 15 the same view controllers show the standard toolbar and the vibrant sidebar.
- No machine here runs macOS 14 or 15, so no screenshot can prove the fallback. If every Mac of the household runs macOS 26, raising the deployment target to 26.0 deletes both checks. Until the owner asks for that, the target stays 14.0 and both checks stay. After such a change, the `cargo clean` of `AGENTS.md` applies.

### Dark mode

Every colour above is dynamic. A page and its picture stay white. Each unit's proof includes its main screen in the dark.

### The icon

- The bundle gains `AppIcon`, rendered from `application/application_icon.svg` by a script, as the iPhone's `render_application_icon.sh` renders its icon. A classic icon set shows on macOS 14, 15, and 26.
- macOS 26 draws its own material for an Icon Composer file. Xcode 27.2 ships `ictool` in `Icon Composer.app/Contents/Executables`, which the design note's open question 19 did not know. I did not run it. The icon step first tries whether an `.icon` bundle written from the drawing's three layers, the plate, the drawer, and the sheets, compiles through the asset catalogue. If it does not, the classic set stays.
- How macOS 26 frames a classic icon in the Dock is from memory uncertain. Only the real Dock shows it.
- The icon appears in the Dock, on the welcome, in the About panel, and in the two notifications. Its drawer, as a one-colour glyph, is the menu bar item and the picture of the empty archive.

### Motion

| Change | Motion |
| --- | --- |
| Rows inserted, removed, revised | The table's own animation, as today |
| A row changes state | Cross-dissolve of the cell's content, 0.25 s |
| "Copied" | Cross-dissolve, 0.15 s in and out |
| Original and Text swap | Cross-dissolve, 0.2 s |
| Quick Look | The panel's zoom from the row's picture |
| The sidebar and the inspector collapse | The split view's own animation |
| The menu bar glyph during an upload | `StatusItemAnimation`, as today |

With `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, the dissolves stay and the glyph holds one frame, as today.

### Sound and haptics

No sound of the application's own. The two notifications take the system's sound. The trackpad's haptics are for alignment and for levels of pressure, so a copied fact gives none.

### VoiceOver and the keyboard

- A document row is one element. Its label is the title, the sender, the date, and the amount, in that order. Its value is the third line. Its picture is not an element.
- A fact is a button with the label "IBAN", the value, and the help "Copies the value."
- A row of Filed Under has the help "Shows the documents of" and the name.
- A sidebar accessory and the status line's symbol have descriptions.
- Tab moves through the sidebar, the list, the reader, and the inspector's rows. The system draws every focus ring.
- Every command is in the main menu, and the Help menu searches them.
- A change of the status line to a refused token is announced.

---

## 10. Small delights

### Kept, because each serves the loop

1. **A click copies a fact**, with "Copied" in its place for a second. Loop step 1, when a bill is paid.
2. **A text match opens on the match**, and Command-G goes to the next. Step 1.
3. **The matched words stand out in the row.** Step 1.
4. **The search field says what it searches.** Step 1.
5. **The window reopens on the document a person was reading.** Step 1.
6. **Quick Look grows out of the row's picture.** Step 1.
7. **An arriving row dissolves into its document**, with its picture already there. Step 2.
8. **The menu bar's newest documents say who sent them.** Step 2.
9. **A folder's page shows the folder as Finder does**, with its icon and a path to click. Step 3.

### Cut

| Idea | Why not |
| --- | --- |
| A row for every file the collector sends | Section 4. Nobody watches, and a backlog has hundreds |
| Tokens and suggestions in the search field | AppKit's search field has neither, and the sidebar shows the scope |
| Swipe actions in the list | The context menu holds every action |
| A Go menu | The scopes are a list the household makes |
| Window tabs and toolbar customization | The application has one window, and its toolbar has six items |
| A thumbnail strip beside the page | A household letter has one to three pages |
| A Dock badge for Needs Attention | The Dock icon is gone while the window is closed. The menu bar glyph says it |
| Core Spotlight for documents | It needs a link into the window and an index kept current. Revisit once the window is right, because finding a letter from Spotlight is what a Mac person would try |
| Widgets | SwiftUI, and reading from a widget is not the loop |
| A serif face for the text | Invoices are numbers in columns |
| Sounds and haptics | Section 9 |
| The iPhone's About footer in Settings | The About panel is the Mac's place |
| Editing, deleting, retrying | The browser. The scope stands |

### SwiftUI

Nothing in this direction needs SwiftUI. SwiftLint keeps refusing it.

---

## 11. Build plan

Six units and one shared step, in the order of the loop. Each unit ends with `scripts/execute_on_macintosh.sh native_client/macintosh_application/scripts/check_application.sh` and one commit on `main`. Each is proven by renders from `scripts/render_interface.sh`, compared with `.audit/macintosh_baseline/`, and by captures of the real screen with Peekaboo after `scripts/start_screen_examination.sh`. The paths below are under `native_client/macintosh_application/` unless they begin with another directory.

Units M1 to M5 stay inside `native_client/macintosh_application/` and `native_client/library_presentation/`. No unit changes a Rust crate.

### Step S1: two pure functions move to the shared module

It touches iPhone files, so it waits until the session that edits them has landed.

1. `native_client/iphone_application/application_interface/DocumentTextViewController.swift`: `TextParagraph` and `paragraphs(of:)` move to `native_client/library_presentation/ExtractedTextParagraphs.swift`.
2. `native_client/iphone_application/application_interface/LibrarySearch.swift`: `matchedRanges(in:searchText:)` and its folding move to `native_client/library_presentation/SearchTextMarking.swift`.
3. Their tests move from `DocumentTextTests` and `LibrarySearchTests` to `native_client/library_presentation_tests/`, so the Mac's check runs them too.

As built, the files are `TextParagraph.swift` and `SearchTextMarking.swift`, because SwiftLint's `file_name` rule requires a file to be named after a type it declares.

Check: both applications' `check_application.sh`. The iPhone's behaviour does not change.

### Unit M1: the window's frame

1. `application_interface/InterfacePalette.swift`: the three tokens of section 9. `link`, `chipFill`, and `chipBorder` stay until the unit that removes their last use.
2. `application_interface/LibraryWorkspaceViewController.swift`, `LibraryDetailSplitViewController.swift`: the flat split view of section 2, after its trial.
3. `application_interface/WorkspaceToolbarController.swift`: plain items, the system's identifiers, the tracking separators, the search field's width, and the removal of items on a page. The Original and Text group waits for M3.
4. `application_interface/MainWindowController.swift`: `tabbingMode`, and a minimum that is true.
5. `application_interface/MainMenuBuilder.swift`: the menus of section 2, with their symbols.
6. `interface_renderer/PaintedToolbarView.swift`, `ScreenRenderer.swift`: the stand-in toolbar follows the new items, the renderer's window follows the appearance, and a new scene `library_minimum_width` shows the window at 900 points.
7. `application_end_to_end_tests/`: the identifiers of the toolbar's items.

Proof:

- Every scene of today in both appearances, with no change but the toolbar's order.
- `library_minimum_width_light.png`: the inspector collapsed, the list and the reader whole.
- Peekaboo: `m1_toolbar_light.png` and `m1_toolbar_dark.png` with Sort over the list and no divider through the toolbar, `m1_view_menu.png` without the tab items and with Show or Hide, `m1_file_menu.png`, `m1_help_menu.png` with a search typed, and `m1_page_toolbar.png` on a folder's page.
- A sentence in the commit that says whether the flat split view stayed, with what the twenty switches showed.

### Unit M2: the list

1. `application_interface/DocumentRowView.swift`, `DocumentListRowView.swift`, `HeadingRowView.swift`: the row of section 4.
2. `native_client/library_presentation/DocumentRowPresentation.swift`: one added property that says whether the third line adds something, and the short date. The iPhone reads this type, so the unit adds and does not change. One test for each.
3. `application_interface/DocumentListViewController.swift`: the context menu, the row height from the fonts, and the search field's placeholder through `WorkspaceToolbarController`.
4. `application_interface/EmptyStateView.swift`, new, in place of `DocumentListEmptyView.swift`. `application_presentation/WindowContent.swift`: the empty archive as a page.
5. `application_interface/QuickLookCoordinator.swift`: the source frame and the transition image.
6. `application_presentation/LibraryNavigationState.swift` and `application_interface/ApplicationPreferences.swift`: the remembered scope and document.
7. `interface_renderer/`: new scenes `library_arriving_and_failed`, `library_empty_scope`, `library_search_no_result`, and `library_first_fill`.

Proof:

- `library_document_pdf_*.png`: two-line titles in the label colour, "Stadtwerke Talbrück GmbH · 22 Sep", the amounts in a column.
- `library_arriving_and_failed_*.png`: an arriving row with its picture, a spinner, and its stage, and a failed row.
- `library_empty_*.png`: one page with the drawer and one button.
- `library_empty_scope_light.png`, `library_search_no_result_light.png`, `library_first_fill_light.png`.
- Peekaboo: `m2_row_context_menu.png`, `m2_selection_window_not_key.png`, `m2_search_placeholder_invoice.png`, and a sentence on whether Quick Look grew out of the row.

### Unit M3: the reader and the inspector

1. `application_interface/ReaderHeaderView.swift`: deleted. `DocumentReaderViewController.swift`: the page under the toolbar, the placeholders through `EmptyStateView`, and the first match scrolled into view.
2. `application_interface/WorkspaceToolbarController.swift`: the Original and Text group.
3. `application_interface/DocumentInspectorViewController.swift`, `InspectorFieldRowView.swift`, `TagChipButton.swift`: the inspector of section 5.
4. `application_interface/SearchWordHighlighting.swift`, `MainMenuBuilder.swift`: Find Next and Find Previous.
5. `application_interface/InterfacePalette.swift`: `link`, `chipFill`, and `chipBorder` removed.
6. `application_end_to_end_tests/ApplicationEndToEndTests.swift`: the test reads the sender's row and the amount from the new rows, and the tab from the toolbar's group.
7. `interface_renderer/`: new scenes `library_document_long_title` and `library_reader_without_inspector`.

Proof:

- `library_document_pdf_*.png` and `library_document_image_*.png`: no band, the title at the inspector's head, Date, Amount, Due, and IBAN before Filed Under, no blue value.
- `library_document_long_title_light.png`: a title of four lines in the inspector.
- `library_offline_missing_original_*.png`: the placeholder with its picture.
- Peekaboo: `m3_page_under_toolbar.png` with a page scrolled under the glass, `m3_fact_under_pointer.png`, `m3_fact_copied.png`, `m3_find_next.png`, and `m3_inspector_focus.png` with the keyboard focus on a fact.

### Unit M4: what arrived and the folders

1. `application_interface/LibrarySidebarViewController.swift`, `SidebarItemCellView.swift`, `SidebarStatusBarView.swift`: section 3, with the context menus and the accessory from macOS 26.
2. `application_presentation/SidebarPresentation.swift`, `SidebarRowAccessory.swift`: no accessory for a collecting folder. Their tests follow.
3. `application_interface/FolderPageViewController.swift`, `PageSectionView.swift`, `NeedsAttentionViewController.swift`: section 6.
4. `application_presentation/BacklogConfirmationWording.swift` and its tests: the two button titles.
5. `application_interface/StatusItemController.swift`: the menu of section 8.
6. `interface_renderer/CollectorScenes.swift`: new scenes `folder_unreadable` and `library_token_refused`.

Proof:

- `folder_collecting_*.png`, `folder_confirmation_*.png`, `folder_surveying_*.png`, `needs_attention_*.png`, re-rendered. The renderer's window is not key, so the default button shows only on the real screen.
- `folder_unreadable_light.png`, `library_token_refused_light.png`.
- `status_item_menu.txt` with one upload line and the subtitles.
- Peekaboo: `m4_sidebar_glass_light.png` and `m4_sidebar_glass_dark.png` with the counts in a column and the status line over a scrolled list, `m4_confirmation_default_button.png`, `m4_sidebar_context_menu.png`, `m4_status_menu.png`, and `m4_folder_path_control.png`.

### Unit M5: first run, the icon, and Settings

1. `application/Assets.xcassets/AppIcon.appiconset`, new, and `scripts/render_application_icon.sh`, new, after the trial of section 9.
2. `project.yml`: the icon's name and the two version keys.
3. `application_interface/ConnectionFormViewController.swift`: the welcome and the replace form of section 7. `StatusMessageViewController.swift`: the start failure through `EmptyStateView`.
4. `application_interface/GeneralSettingsViewController.swift`, `ArchiveSettingsViewController.swift`, `StorageSettingsViewController.swift`: section 7.
5. `interface_renderer/`: `connection_form` becomes `welcome`, with new scenes `welcome_refused`, `replace_token`, `start_failure`, `settings_general`, `settings_archive`, and `settings_storage`.
6. `application_end_to_end_tests/`: the form's identifiers stay, so the test that connects through the form passes unchanged.

Proof:

- `welcome_*.png`, `welcome_refused_light.png`, `replace_token_light.png`, `start_failure_light.png`, and the three Settings scenes.
- Peekaboo: `m5_dock_icon.png`, `m5_about_panel.png` with the icon and a version, `m5_welcome_key_window.png` with the focus ring and the filled Connect, and `m5_settings_archive_key.png`.

### Unit M6: marked matches and the readable text

It needs step S1.

1. `application_interface/DocumentRowView.swift`: the excerpt with its marked words.
2. `application_interface/DocumentReaderViewController.swift`: the text of section 5 from `TextParagraph`, the marked matches, and the Text tab for a match the original cannot show.
3. `interface_renderer/`: a new scene `library_document_text` with a page mark and a table.

Proof:

- `library_search_text_*.png`: "Haftpflichtversicherung" semibold in the excerpt and marked in the text, and no "#" in the heading.
- `library_document_text_*.png`: a page mark, a table in the monospaced font, a column of at most 680 points.
- Peekaboo: `m6_text_match_opens.png`, a row under "Matches in Text" chosen and the match in view.

### Order and dependence

- M1 comes first, because every later unit lays out inside its split view and reads its palette.
- M2 and M3 are the loop's first step. M3 needs M1's toolbar for the Original and Text group.
- M4 and M5 depend on M1 only. The icon step of M5 depends on nothing, and it can come first if the generic icon in the Dock matters more than the order of the loop.
- M6 depends on S1, M2, and M3. If the iPhone session lands early, S1 can come before M2, and M2 and M3 then take M6's parts.

### After each unit

- `notes/native_client_design.md` gets its reconciliation paragraph, as units A1 to A5 have theirs. Its lines on the reader's header, the hover copy control, the links of the inspector, and the checkmark of a collecting folder describe the build this direction replaces.
- `AGENTS.md` gets the changed file descriptions of `application_interface/` and `interface_renderer/`. Another session edits `AGENTS.md` at the time of writing, so a unit rereads the file before it writes.

## 12. What only the real screen shows

The build account's session is not the Mac's console session. The captures of 2026-11-23 could therefore not show a context menu, the Share popover, a focus ring, or the Space key, and they show Settings in a window that is not key. Each of these needs the owner at the Mac, or a session in which the build account owns the console.

- The toolbar's glass over the list and the page, the scroll edge effect under the toolbar, and the sidebar's glass over the wallpaper.
- The status line as the sidebar's bottom accessory, with rows passing under it.
- The key window: the default buttons, the focus rings, the tab order, and the selection's two states.
- Every context menu, which the application gains with this direction, and the symbols beside the menus' items.
- Whether Show Sidebar and Show Inspector change their titles by themselves.
- The fact under the pointer, the click that copies, and "Copied".
- Quick Look from Space, its zoom from the row's picture, the Share popover, and a drag into Finder and Mail.
- The Dock icon as macOS 26 frames it, the About panel, and the notifications' icon.
- The menu bar glyph at its real size in both appearances, and the menu's subtitles.
- VoiceOver over the list, the inspector's facts, and the status line.
- The window at 900 points, and the dividers after a page and back.
- macOS 14 and 15. No machine here runs them.
