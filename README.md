# Ezra

A personal project manager for macOS: to-dos in the style of Things (Inbox, Today with
This Evening, Upcoming, Anytime, Someday, Logbook, areas, projects with headings), Markdown
note pages and an on-device AI assistant. SwiftUI + SwiftData, Swift 6, macOS 26 or later.

## Download

**[Download Ezra 0.1.0 for Mac](https://github.com/sjlouji/Ezra/releases/latest/download/Ezra-0.1.0-mac.zip)** (7 MB zip, Apple silicon and Intel) · [all releases](https://github.com/sjlouji/Ezra/releases)

- Needs macOS 26 or later.
- Unzip it and move Ezra to Applications. The build is not notarized, so the first time right-click Ezra and choose
  Open, or allow it under System Settings › Privacy & Security.
- Sync is off in the download: it contains no Firebase project settings. To use sync, build from source with your own
  `Ezra/GoogleService-Info.plist`.

## Run

```bash
xcodegen generate
xcodebuild -project Ezra.xcodeproj -scheme Ezra -derivedDataPath build build
open build/Build/Products/Debug/Ezra.app
```

`Ezra.xcodeproj` is generated from `project.yml`; change the project there, not in Xcode.
The app is signed with the Apple Development certificate named in `project.yml`.

## Test

```bash
xcodebuild -project Ezra.xcodeproj -scheme Ezra -derivedDataPath build test
```

Prefix with `TEST_RUNNER_EZRA_LIVE_MODEL=1` to include the tests that talk to Apple's
on-device model (needs Apple Intelligence turned on).

## Layout

| Path | What is there |
|---|---|
| `Ezra/Brand/Theme.swift` | App name, on-screen words, colours, fonts. Rebrand here. |
| `Ezra/Brand/ListIcons.swift` | Every list icon, drawn in code. |
| `Ezra/Models/` | SwiftData models (`ToDo`, `Project`, `Area`, …), list rules (`SmartList`), and `Workspace`, the one place data is changed. |
| `Ezra/Data/Fixtures.swift` | Demo areas, projects, to-dos, tags and calendar events, as day offsets from today. |
| `Ezra/Data/Seeder.swift` | Seeds the demo once, flags it, and shifts its dates forward each launch. |
| `Ezra/Data/AppModel.swift` | Navigation, the open to-do card, the When / Deadline picker. |
| `Ezra/Data/DemoScript.swift` | Launch arguments for demos and screenshots. |
| `Ezra/Features/<Screen>/` | One folder per screen: Shell (window, bottom toolbar), Home (the sidebar), Today, Upcoming, Lists (Inbox, Anytime, Someday), Logbook, Project (and Area), Card, When, QuickFind, Settings, Notes, Assistant, Planner. |
| `Ezra/Assistant/` | The chat model and the tools the on-device model calls. |
| `Ezra/Sync/` | Sync through the user's own Firebase project: email sign-in, the Firestore client, and the engine that sends and applies changes. |

## Demo data

The sample content is flagged `isDemo`. Settings has **Reset Demo Data** (replace it with a
fresh copy) and **Remove Demo Data** (delete it). Neither touches your own items.

Launch arguments:

```bash
open build/Build/Products/Debug/Ezra.app --args -DemoScreen upcoming
open build/Build/Products/Debug/Ezra.app --args -DemoTour YES
open build/Build/Products/Debug/Ezra.app --args -ResetDemo YES
```

`-DemoScreen` takes: today, planner, inbox, upcoming, anytime, someday, logbook, project, area, card,
new, when, deadline, quickfind, settings. Add `-DemoSnapshot YES` to save a PNG of each
screen shown into the app's temporary folder
(`~/Library/Containers/app.ezra.Ezra/Data/tmp/`).

## Things to know

- Calendar events are demo fixtures; the app does not read your calendars.
- iCloud sync is off. The steps to turn it on (paid developer team needed) are at the top
  of `project.yml`.
- Sync is optional and signs in under Settings. It needs `Ezra/GoogleService-Info.plist` from your Firebase project
  (kept out of git); without it the app runs purely locally. The only network traffic is to that project.
  The old service connectors are archived in `.removed/` (not in git).
- The assistant runs on Apple's on-device model. It is small: long chats fill its context,
  and a failed turn starts a fresh conversation.

## Things-style features

- **When and reminders**: ⌘S opens the When popover. Type a phrase ("tomorrow", "next fri", "in 3 days", "sat 9am"); a time sets a reminder. Reminder notifications offer snooze (15 min, 1 hour, 3 hours, tomorrow). Logic in `Models/WhenPhrase.swift`, `Models/ReminderScheduler.swift`.
- **Repeating**: a to-do or project can repeat on a schedule or after completion (`Models/Repeat.swift`). The template is hidden from every list except Repeating; copies point at it through `templateUUID`.
- **Apple Calendar**: Settings → Connect Apple Calendar. Events are read through EventKit (`Models/CalendarService.swift`) and shown on Today and Upcoming. Read-only.
- **Add from other apps and agents**: `ezra:///add?title=&notes=&when=&deadline=&tags=&checklist-items=&list=&heading=` (`Data/ExternalCommands.swift`), and an "Add To-Do" Shortcuts action (`Data/ShortcutsActions.swift`). Example: `open "ezra:///add?title=Call%20bank&when=tomorrow"`.
- **Quick Find**: ⌘F, or just start typing on any list. Finds to-dos, projects, areas and the special lists; "Continue Search" also looks in notes, checklists and the Logbook.
- **Notes**: to-do and project notes are a live Markdown editor (`Features/Shared/MarkdownEditor.swift`); ⌘B and ⌘I.
- **Moving**: ⇧⌘M opens the Move panel (lists, areas, projects, headings). ⌘T today, ⌘E this evening, ⌘R anytime, ⌘O someday, ⇧⌘D deadline, ⌘K complete.
- **Quick Entry**: ⌃Space from any app opens a small entry panel (`Features/QuickEntry/QuickEntry.swift`). If macOS uses ⌃Space for input sources, one of the two has to change.

Not built: Quick Entry with Autofill, multi-select, auto-scroll while dragging, repeat on selected weekdays, repeat with deadlines.

## Assistant

- **Name**: shown as "Ezra"; change `Brand.assistant` in `Brand/Theme.swift` to rename it everywhere.

- **Ollama** (`Assistant/OllamaAgent.swift`): a third engine. It talks to Ollama on `localhost:11434`, lists the installed chat models in Settings, gets every tool (pages included) but no web. Thinking is switched off (8x faster per round with `qwen3:14b`); input over 40,000 characters is refused, because Ollama would cut it silently. Live test: `TEST_RUNNER_EZRA_LIVE_OLLAMA=qwen3:14b`.
- **Apple and Claude** (`Assistant/ChatModel.swift`, `AssistantEngine`): Apple's on-device model (free, private) or Claude (`claude-opus-5-5`) through the user's own API key. The key is typed in Settings and kept in the Keychain (`Keychain.claudeKey`); the switch is in Settings and in the chat header.
- **One tool list for both** (`Assistant/AgentTools.swift`, `AgentChangeTools.swift`): each `AgentTool` is described once; `OnDeviceTool` offers it to FoundationModels and `ClaudeAgent` sends its JSON Schema to Claude. Claude also gets Anthropic's web search and web fetch. Arguments marked `onDevice: false` are Claude-only (the on-device context is small).
- **Claude over plain HTTPS** (`ClaudeClient.swift`, `ClaudeAgent.swift`): no Swift SDK exists. Requests are not streamed: each tool round is one request and Claude's reply blocks are sent back unchanged. Earlier turns are replayed as text.
- **Steps** (`ChatStep`): every tool call is shown in the chat (running, done, failed), saved with the reply (`ChatMessage.stepsData`) and synced. `showTasks` puts a live table of to-dos in the chat: tick off, reschedule, click through.
- **History** (`Features/Assistant/ChatHistory.swift`): search, pin, rename, delete.
- **Files** (`Assistant/ChatFile.swift`): attach or drop text, Markdown, transcripts, CSV, JSON, PDF, Word or RTF. The text is read out and saved with the message as an `attachment` step, so later turns and other devices have it. Limits: 400,000 characters per file; 6,000 for the on-device model, which refuses longer text with the reason.
- **Pages** (`ChatPage`, tool `showPage`, Claude only): Claude writes a self-contained HTML page (chart, timeline, board) shown in a web view in the chat. A Content-Security-Policy added on load blocks every network request.
- **Replies** render Markdown including tables and fenced code (`ReplyMarkdown` in `Models/NoteMarkdown.swift`, `Features/Assistant/ChatArtifacts.swift`).
- Not built: word-by-word streaming for Claude, deleting to-dos or projects from the chat, images and scanned PDFs as attachments, saving a page as a file.

## Settings and icon

- **Settings window** (`Features/Settings/SettingsWindow.swift`, `SettingsPanes.swift`): a standard `Settings` scene (⌘,) with tabs General, Sync, the assistant, Quick Entry, Reminders and Calendar. `EzraApp` creates the one `ChatModel` both windows use.
- **Icon** (`Tools/make-icon.swift <light|dark> <day|night> <out.png>`): four variants. The asset catalog's `AppIcon` is light day; `Icon-<light|dark>-<day|night>` image sets are what `App/DockIcon.swift` puts in the Dock while the app runs, by the Mac's appearance and the hour (day is 6:00 to 18:00), or by the choice in Settings › General. Finder and a closed app always show light day.

## Drag and drop

- **To-dos** reorder within their run and drop on sidebar lists, projects, areas, headings, planner days and buckets (`Data/DragDrop.swift`).
- **Notes, projects and areas** use `Data/SortDrag.swift`: a row marked `.sortable(item, in: group)` reorders among its own kind (rows part as it passes) by taking a position halfway between its new neighbours. A project dragged into another area's list joins that area. A note dropped on a sidebar project is filed there; on the Notes entry it leaves its project. `Note.order` is new and synced.
- **Feedback**: while dragging, the entries that take the item are outlined, and a label on the dragged item says what dropping will do (`DragItem.hint(for:)`). Entries that would do nothing do not light up (`DragItem.accepts`).
- Not draggable yet: headings inside a project, checklist items, chats, and notes while the list is filtered by a search (they can still be dropped on a project).

## Planner calendar

The Planner has a Day / Month / Year switch (`Features/Planner/CalendarViews.swift`, remembered in `planner.mode`). `PlannerBar` holds the title with previous/next arrows, a Today button and a jump popover (year stepper in ones and tens over the twelve months). `MonthView` shows each day's events, deadlines and planned to-dos; `YearView` shows twelve small months with a dot on busy days. A click on a day opens it in Day view; a to-do can be dropped on any day. Date logic is in `Models/Planner.swift` (`monthGrid`, `months`, `shifted`, `load`); Apple Calendar counts for a whole year come from one query (`CalendarService.eventCounts`). There is no week grid: Day view keeps its week strip.

## Added 2026-11-12 (batch of fifteen)

- **Dark mode**: every `Brand.Palette` colour has a dark value (`Color(hex:dark:)`); Settings › General › Theme picks Match the Mac / Light / Dark (`Brand.Appearance`).
- **Repeats**: weekly rules can name weekdays (`RepeatRule.weekdays`) and copies can carry a deadline (`deadlineAfter`). **Templates**: `Project.isBlueprint`; Save as Template in a project's menu, New Project from Template under New List and in the Templates list (`Workspace.saveAsTemplate`, `stampOut`).
- **Links** (`Models/NoteLinks.swift`): `[[Note title]]` in a note or a to-do's notes. Notes show what links to them and the to-dos that mention them; an open to-do shows chips for its linked notes.
- **Memory**: the tool `remember` writes to the note "What Ezra Remembers"; its lines go into every chat's context. Editing the note is how to forget.
- **Saving a page**: the Save menu on a chat page (to Notes with the HTML attached, or as a file).
- **Daily briefing** (`Models/DailyBriefing.swift`, `Features/Today/BriefingCard.swift`): a card on Today, once a day; optional 8:00 notification in Settings › Reminders.
- **Streaming** (`Assistant/LineStream.swift`): Claude (server-sent events, rebuilt by `ClaudeStream`) and Ollama (one JSON document per line) replies are shown as they arrive. `LineTransport` replaces the old transport for both.
- **Pictures and scans** (`Assistant/ChatFile.swift`): pictures are read with on-device text recognition and, for Claude, sent as a JPEG of at most 160 KB (two per message); a PDF with no text layer is read page by page the same way.
- **Voice** (`Assistant/Dictation.swift`): a microphone button in the chat box and in Quick Entry.
- **Multi-select** (`Data/Selection.swift`): ⌘-click and ⇧-click pick to-dos; the bottom bar then offers Today, Tomorrow, Someday, Tag, Move, Complete, Delete.
- **More dragging**: headings, checklist items (their creation time is their position) and chats (onto Pinned / Chats).
- **Week grid** (`Features/Planner/WeekView.swift`): the Planner's Week view; dropping a to-do on an hour sets its day and a reminder at that time (`DropTarget.hour`).
- **Menu bar** (`Features/Shell/MenuBarItem.swift`): today's count, quick add, tick off. Its `isInserted` binding must not write an unchanged value, or the app redraws forever.
- **Widgets** (`EzraWidgets/`, `Shared/WidgetSnapshot.swift`, `Data/WidgetFeed.swift`): a second target. The app writes `widgets.json` into the app group `Z7V2UFGTCB.app.ezra.Ezra` after each save and asks WidgetKit to reload.
- **Tool arguments**: Claude and Ollama run with `AgentToolbox.strict`, so a required argument that is missing (tags, most often) is sent back to the model. The on-device model is not strict and gets a shorter tool list (no `remember`, `addArea`, `showPage`).

## Chat features added 2026-11-12 (from Open WebUI's list)

- **Per-chat settings** (`Assistant/ChatParams.swift`, panel in `Features/Assistant/ChatControls.swift`): instructions, Claude effort and web search, Ollama temperature, show reasoning, follow-up suggestions, and "also ask" other models. Saved on `ChatThread` (`instructions`, `paramsData`) and synced. Standing instructions for every chat are in Settings.
- **Folders**: `ChatThread.folder`; Move to Folder in a chat's context menu.
- **Queue**: a message sent while a reply is being written waits in `ChatModel.queue`; waiting messages go together afterwards.
- **Follow-ups**: capable models end with a `Follow-ups: a | b | c` line (`ChatText.followUpRule`), which is cut off the reply and shown as chips.
- **Reasoning**: Claude's summarised thinking and Ollama's `thinking` become a "Thought" step.
- **Compare models**: engines in `params.alsoAsk` answer the same message after the chosen one, with read-only tools; replies are labelled.
- **Tools the chat carries out** (`AgentToolbox.extras`, `ChatModel+Answering.swift`): `setTimer` (in memory; its prompt returns to the chat), `notify`, `delegate` (sub-agents run side by side with the same tools). Plain new tools: `dateMath`, `plan`.
- **Automations** (`Assistant/Automations.swift`, Settings tab): scheduled prompts, stored in this Mac's preferences, run by `AutomationRunner` once a minute while the app is open.
- **Autocomplete** (`PromptPredictor`): the on-device model guesses how the message continues; Tab takes it.
- **Voice mode**: the speaker button reads replies aloud and sends dictation when you stop speaking.
- **Sharing**: `ChatText.markdown(of:)` through the system share sheet. **Link**: `ezra:///chat?q=…&model=claude|ollama|mac` fills the box and never sends by itself.
- **Shortcuts**: listed in Settings › Shortcuts; not rebindable.
- Not built: Python code execution, Mermaid rendering, comments, merging several models' answers, a stop button, timers that survive quitting.
- **Seeing the work** (`Features/Assistant/ChatSteps.swift`): a reply is a timeline. Each tool call is a `StepRow` (label, subject, a clock while running, the time taken after) that opens to show what was sent (`ChatStep.input`), what came back and its state; what the model says between calls is kept in place as a `say` step; `PlanCard` shows the model's own plan with the step in hand turning. While a reply is being made a status line shows `ChatModel.activity` with a clock and a Stop button (⌘.), which cancels `ChatModel.working`.

## React artifacts

`buildArtifact` (Claude and Ollama) takes one TSX component file and shows it in the chat. The runtime is `Ezra/Resources/ArtifactKit/`: `kit.js` (React 18, the 43 shadcn/ui components, lucide-react, Recharts and the Sucrase compiler, one IIFE exposing `EzraKit.run(source)`), `tailwind.js` with `tailwind-config.js` (Tailwind's in-browser compiler and the shadcn theme), `theme.css` (the colour variables), and `check.js` (`EzraCheck.check(source)`, run inside the app with JavaScriptCore before a page is shown). `Assistant/ArtifactKit.swift` checks a file (compiles, exports a component, imports only what the kit has, loads nothing) and builds the page; a failure goes back to the model as the tool's error. Pages allow `unsafe-eval` for the compiler but still no network.

The kit was built once from Anthropic's artifacts-builder skill (Apache 2.0): run the skill's `scripts/init-artifact.sh`, add `sucrase` and `recharts`, copy `Tools/artifact-kit/*` into the project, then `pnpm exec vite build --config vite.kit.config.ts` and `--config vite.check.config.ts`; `tailwind.js` is `https://cdn.tailwindcss.com/3.4.17`. Rebuild only to add libraries or components.

## Trackpad gestures

`Data/Gestures.swift`. `SwipeMonitor` watches two-finger scroll gestures in the main window and turns a long sideways one into a `Swipe`; `AppModel.swiped(_:at:)` acts on what is under the pointer: right on a to-do opens When, left selects it (multi-select), left on a checklist item deletes it, and anywhere else right/left goes back/forward along `AppModel.trail` (also ⌘[ and ⌘]). The row slides a little with the fingers (`swipeOffset`, `SwipeHint`). Pulling a list down past its top opens Quick Find (`ScreenList`). These follow Things' documented iPhone/iPad gestures; Cultured Code documents none for the Mac trackpad.

## Dashboards

`showDashboard` (`Assistant/AgentShowTools.swift`, `Assistant/Dashboard.swift`) is the default "artifact": the model sends data only (`kpis`, `charts` of type bar / line / donut / progress, an optional `table`, `notes`) as a structured argument (`Parameter.Kind.object` with `Dashboard.schema`), and the app draws the page: one stylesheet, SVG charts, a table that sorts on a heading click. Model text is escaped. `buildArtifact` and `showPage` remain for things a dashboard cannot be.

## Workload dashboard, Ollama speed, sidebar

- `showWorkload` (`Assistant/WorkloadDashboard.swift`) takes no arguments: the app computes the user's workload dashboard from the store (`Dashboard.workload`). It is the answer to "my workload" or "an artifact about my work" for every engine, the on-device one included.
- **Ollama prompt caching**: `OllamaAgent` keeps the system message constant (instructions only) and puts the changing context (time, tags, memory, instructions) in a `<context>` block on the newest message, so Ollama reuses its work on the ~4,000 tokens of tools and instructions instead of re-reading them every message (about 15 s with qwen3:14b).
- `AgentTools.timing(when:reminder:)` accepts muddled date arguments from small models (a time in `when`, a bare time or words in `reminder`).
- **Sidebar**: `AppModel.sidebarHidden` (remembered). It slides under the left edge with a spring; ⌘/, the button by the window controls, a two-finger swipe left over it / right from the left edge, or dragging or double-clicking its edge (`SidebarEdge` in `RootView.swift`).

## Load testing

- **Try it**: `open build/Build/Products/Debug/Ezra.app --args -LoadTest 5000` opens the app on a made-up store of that many to-dos (`Data/LoadTest.swift`; store file `load-test.store`, rebuilt each launch). Nothing syncs, and widgets and automations stay on the real data. A red banner says so. Quit and open normally to return to the real data.
- **Measure it**: `TEST_RUNNER_EZRA_LOAD=5000 xcodebuild … test "-only-testing:EzraTests/LoadTests/theHeavyOperationsAtScale()"` prints `EZRA-LOAD` lines: data operations and how long each screen takes to draw. `TEST_RUNNER_EZRA_PROFILE=month` runs `drawThePlannerRepeatedly` for use with `sample`.
- **What it led to (2026-11-12)**: lists build rows lazily (`ScreenList`, sidebar, notes list, planner buckets use `LazyVStack`); the month and week views sort to-dos and events into days once per draw; `CalendarService.events(in:)` fetches a range in one query; the sidebar reads its query once. At 5,000 to-dos every screen draws in 0.25 to 0.7 s (Logbook was 11 s, Anytime 6 s).

## The shared library of to-dos

`Data/Library.swift`. The window, the sidebar and the menu bar no longer each fetch every to-do with their own `@Query`: SwiftData re-ran every such query after every change (a typed letter included), which at 5,000 to-dos cost about 440 ms per keystroke. `Library` fetches the open to-dos once (`open`), keeps the sidebar's counts, and fetches again only on `ModelContext.didSave`; completed to-dos (`done`) are kept only once a screen calls `wantDone()` (the Logbook, a widened Quick Find). Views read `@Environment(Library.self)`; `RootView` supplies it (and makes one if none is passed), `EzraApp` shares one between the window and the menu bar. A view drawn on its own in a test needs `.environment(Library(context:))`. Data changed without a save does not reach the lists until the next save; `Workspace` saves on every change.

Measure interactions with `TEST_RUNNER_EZRA_LOAD=5000 … "-only-testing:EzraTests/LoadTests/theEverydayActionsAtScale()"` (`EZRA-ACT` lines); add `TEST_RUNNER_EZRA_PROFILE=typing` or `=ticking` to loop one action for `sample`.

## Paging from the database (step 1)

The rules of the lists also exist as database conditions (`Ezra/Data/ListQueries.swift`), so a list can be counted or
fetched a page at a time without loading every to-do. `ListQueryTests` builds every combination the rules tell apart
(1,024 to-dos) and checks each condition returns exactly what `SmartList.contains` does.

- The sidebar's Inbox, Today and overdue counts are database counts.
- The Logbook fetches 100 completed to-dos, newest first, and another 100 when its end scrolls into view. Opening it no
  longer makes every later save load all completed to-dos.

Measured (`TEST_RUNNER_EZRA_LOAD`): a Logbook page takes 6 ms at 5,000 to-dos and 19 ms at 50,000; opening the Logbook
takes 67 ms and 126 ms. The other lists still load every open to-do: at 50,000, re-reading them after a save takes about
1 s and switching lists 0.5–2 s. Paging those lists the same way is step 2.

## Notes inside the lists

There is no separate Notes section. A note is an item like a to-do and lives in one place: a project (under a heading
or not), an area, or the Inbox.

- Note rows sit under the to-dos of a project, heading, area and the Inbox; clicking one opens it as a page with a back
  arrow. New Note is in the bottom toolbar and in the project and area menus, and files the note where you are.
- A note can be attached to any number of to-dos (`ToDo.noteIDs`). An open to-do shows its notes as chips with an
  Attach note menu; a row shows a page mark. `[[Title]]` written in a to-do's notes still counts as an attachment.
- The note page lists the to-dos it is attached to; "New to-do from this note" makes one already attached and filed
  beside the note.
- Quick Find finds notes by title (and by text after Continue Search) and offers an All Notes list.
- Dragging a note onto a sidebar project, area or the Inbox files it there; within its list it reorders.

Screens rendered from the app with a developer's and a product owner's data are in `docs/notes-workflow/`
(`TEST_RUNNER_EZRA_SNAPSHOTS=1`, screens `notes-*`).

## Menu bar, sidebar menus, dragging between sections

- **Menu bar** (`Ezra/App/Menus.swift`): File (New To-Do ⌘N, New Note, New Heading, New Project ⌥⌘N, New Area), Edit
  (Quick Find… ⌘F), View (Hide Sidebar ⌘/, Go To ⌘1–⌘7 and ⌘J, Back ⌘[, Forward ⌘]), Items for the open to-do (When… ⌘S,
  Move… ⇧⌘M, Deadline… ⇧⌘D, Today ⌘T, This Evening ⌘E, Anytime ⌘R, Someday ⌘O, Complete ⌘K, Remove From Project,
  Show in Project ⌘L, Delete) and Window (Quick Entry). Every window shortcut lives there, once.
- **Right-click** a sidebar list, project or area for its actions: new to-do, note or heading there, complete or reopen
  a project, move it to an area, save it as a template, delete (with a confirmation).
- **Dragging between sections**: a to-do dropped on a row or header of another section joins it. Today and This Evening
  (the evening header appears while dragging), the days of Upcoming, the projects and areas of Anytime and Someday,
  and the headings of a project.
- The sidebar's list scrolls below the window buttons, not under them. Text is one point larger throughout.

## The note editor

A note is stored as Markdown and edited as blocks (`Ezra/Models/NoteBlocks.swift`, `Ezra/Features/Notes/BlockEditor.swift`,
`BlockRows.swift`). Each line shows as what it is while it is typed: headings, bulleted, numbered and nested lists,
checkboxes, quotes, fenced code, dividers and pipe tables; bold, italic, `code`, ~~strikethrough~~ and links are styled
in place with their marks dimmed.

- Start a line with `# `, `## `, `### `, `- `, `1. `, `[] `, `> `, three backticks or `---` to make that block.
- Return carries a list on and leaves it on an empty item; Backspace at the start of a line makes it plain text, then
  joins it to the line above; Tab and Shift-Tab nest list items; the arrows move between blocks.
- Hover a block for its handle: the plus adds a block below; drag the grip to move the block, or click it to turn the
  block into another kind, duplicate or delete it.
- Pasted Markdown becomes blocks. A table is edited cell by cell; rows and columns are added at its edges and removed
  by right-clicking a cell.
- Nothing in the interface shows or names Markdown: the marks for bold, italic, code and links are hidden and appear,
  dimmed, only around the cursor. Opening a note never rewrites it; the stored Markdown changes only when you edit.
- A block's height is measured from its text at the offered width (`MarkdownTextField.sizeThatFits`), never from the
  text view's own layout; measuring from the view made long lines spill over the next block.

## Layouts in notes

A note can hold layouts: blocks side by side in columns, or in a grid of cells (`BlockLayouts.swift`,
`NoteBlockEdits.swift`). The plus on a block's handle offers 2, 3 and 4 Columns, Wide Left, Wide Right, Grid 2 × 2 and
Grid 3 × 2. Each cell holds blocks of its own (headings, lists, checkboxes, tables and so on), typed and edited as
anywhere else. Blocks are dragged into, out of and between cells. A layout's handle adds or removes columns and cells,
makes the widths equal, takes the layout apart keeping its text, or deletes it.

A layout is one kind of block with relative column widths; more cells than columns wrap into further rows, which is
what makes a grid. In the stored Markdown a layout is three comment lines (`<!-- layout 2:1 -->`, `<!-- cell -->`,
`<!-- /layout -->`) around the cells' ordinary Markdown, so other apps show the cells one after another.

## Claude can use Ezra (MCP)

Claude Code and the Claude desktop app can read and change your to-dos, projects, notes and calendar through the same
tools Ezra's own assistant uses (`MCPService.swift`: 16 tools, read and write).

- **Switch it on:** Settings › Claude › Let Claude use Ezra. Off by default.
- **Claude Code:** Copy the Command, paste it into Terminal, start a new session.
- **Claude desktop app:** Add Ezra to the Claude Desktop App…, choose `claude_desktop_config.json` in the window that
  opens (it starts in `~/Library/Application Support/Claude`), press Add, then quit and reopen Claude. Ezra merges its
  entry into that file and keeps the rest. Copy the Settings Entry is there for doing it by hand.

How it is put together: Ezra listens on 127.0.0.1 only (`MCPServer.swift`, port 47821) and answers JSON-RPC over HTTP
POST. Claude starts `Ezra.app/Contents/MacOS/ezra-mcp` (`EzraMCP/main.swift`), which passes Claude's messages to Ezra
and opens Ezra when it is not running. Every request must carry a token Ezra made and keeps in the Keychain; the copied
setup contains it. A request with an Origin header (a web page) is refused, with or without the token. Settings › Claude
can make a new token, which cuts off what was set up with the old one.

To try it without touching real data: `open -n Ezra.app --args -LoadTest 200 -MCPTestToken <any> -MCPTestPort 47990`,
then pipe JSON-RPC lines to `ezra-mcp` with `EZRA_MCP_TOKEN` and `EZRA_MCP_PORT` set. The test token is honoured only
in load-test mode.

