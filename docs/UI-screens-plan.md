# Study Tracker — UI Remap

Sep 30, 2026 · @Gibson Wade

## Design principles

The redesign rests on seven rules. Every screen, row and button below is checked against them, and a proposal that breaks one needs a written reason.

1. **Always a next step.** No screen is ever blank. An empty screen shows the single most useful action for that screen, and every suggestion can be dismissed or snoozed.
2. **If it looks clickable, it is.** Every row that represents a thing (class, study block, assignment, material, card, course) opens that thing. Decorative rows are restyled so they stop looking like buttons.
3. **One canonical home per thing.** Each object type has exactly one detail view, reached the same way from everywhere. Other screens show it in an inspector or jump to that home.
4. **Everything has an address.** Every screen, tab, Settings section and object has a route (`studytracker://…`). Buttons, the command palette, the menu bar, notifications and toasts all navigate by route, so deep links can't drift.
5. **Nothing is lost by accident.** Every destructive action is soft and undoable: a toast with Undo, then a 30-day Recently Deleted list.
6. **Claude is one feature, not three.** One button label per task, one queue, one Activity log that always shows what Claude did, is doing, or is waiting on.
7. **Counts never lie.** A badge equals the number of rows the screen shows, computed by the same query.

Connections (Moodle, calendars, Claude) move out of Settings into a visible, first-class place, because connecting is the first thing a new user does. Visual style moves into a token-based theme system so every theme ships a light and a dark variant.

## Audit: problems and fixes

All 14 observations from the screens doc (§6) plus your own notes map to a fix. None is left as "known issue."

| # | Problem today | Fix in the redesign | Principle |
| --- | --- | --- | --- |
| 1 | Settings can't be deep-linked; "Import your timetable" lands on the last-open section | Route for every Settings section and every Connection; buttons navigate by route | 4 |
| 2 | No screen shows one material in full; syllabi, briefs and past exams unreachable from Study | New **Material page**: the canonical home for any file, with the study flow for lectures and extraction for syllabi | 3 |
| 3 | Calendar popover "Details" only opens course Overview | Popover gets three links: course, its assignments, the related material | 2, 3 |
| 4 | Menu bar "Suggested" and "Due soon", Today's class list, Agenda class and study-block rows, Month cells do nothing | Every row opens its object (popover in place, or jump via route) | 2 |
| 5 | Month view hides study blocks and busy time | Month shows study blocks as small chips and busy time as a day-cell tint, both governed by Layers | 2 |
| 6 | Selections persist across screens silently | Back/Forward history (⌘\[ / ⌘\]) plus a visible restored-state cue; persistence becomes intentional | 3 |
| 7 | Claude button behaves three ways, label changes, no persistent log | One label per task, a run-mode setting, a job queue and an **Activity** panel | 6 |
| 8 | Second Claude job shows an error | Jobs queue instead of failing | 6 |
| 9 | Deleting course, term, material, or "Clear all" has no Undo | Soft delete everywhere, Undo toast, 30-day Recently Deleted | 5 |
| 10 | Suggested-action rules in SPEC differ from code (8 outcomes, 14-day exam window) | Code becomes the source of truth; one rules table in this doc replaces SPEC §7.3 | 7 |
| 11 | SPEC shortcut list omits Settings ⌘, | Shortcut table regenerated from the route list | 4 |
| 12 | Long course tabs, hard caps (Deck 100, questions 30, Inbox cards 12), no sort | Sortable, filterable, paged lists; caps removed | 1 |
| 13 | Moodle is the only screen with green and animation | Success color and connect motion become theme tokens used by all Connections | Themes |
| 14 | Study step cards fixed height with uneven content | Steps become a vertical timeline with the active step expanded | 1 |
| 15 | Inbox badge ignores syllabi, briefs, past exams | Badge = row count, same query | 7 |
| 16 | Connections are hidden in Settings | First-run setup flow plus a **Connections** screen in the sidebar with live status | 1 |
| 17 | Empty screens with no clear first action | Every empty state becomes a Next Step card; suggestions dismissable | 1 |
| 18 | One fixed look | Themes, each with light and dark | Themes |

## Navigation map

The window keeps one sidebar with three groups, and every row anywhere opens one of five canonical homes. Settings, the menu bar extra and first-run setup sit outside the window and enter it by route.

&#91;embedded content: navigation map · sidebar, five canonical homes, three outside surfaces\]

The sidebar groups are **Screens** (Today, Inbox, Calendar, Assignments, Study), **Courses** (one row per course, archived ones collapsed), and **Connections** (Moodle, Calendars, Claude, Apple Calendar, each with a status dot). Review, Handwriting, the scope dialog and the editors stay modal sheets.

## Screen-by-screen remap

Two screens are new (Material page, Connections), one is a new flow (First-run setup), and Settings moves to its own native window. Everything else keeps its purpose but gains full interactivity and a next step.

### First-run setup (new)

A full-window flow shown on first launch, replacing the Today onboarding card. Each step is skippable, progress is saved, and quitting midway resumes at the same step.

1. **Welcome**: one sentence on what the app does, **Get started**, and **Explore with sample data**.
2. **Your school (Moodle)**: the existing address field with live school lookup and **Connect with {provider}**. On success it offers to create courses and the current term from Moodle, which removes steps 3 and 4 for most users.
3. **Term**: name and dates, prefilled from Moodle when possible.
4. **Timetable**: import an .ics (iCalendar) file or subscribe to a calendar link; shows the existing preview inline, not as a sheet.
5. **Claude**: connect Claude Desktop through the app's MCP (Model Context Protocol) server, and pick a run mode (see Cross-cutting systems).
6. **First files**: a drop zone for slides or PDFs; files go straight to the Inbox.
7. **Done**: a summary of what's connected and what was skipped, then Today.

Anything skipped becomes an item in Today's Setup checklist and a "Not connected" row in Connections.

### Today

Answers "what now" in one glance. Layout top to bottom:

- **Header**: date and greeting, plus a small connection-health dot that turns accent-colored when a sign-in has expired.
- **Next up** (hero card): the suggested action with one primary button, a detail line, and two quiet controls: **Not now** (snoozes this suggestion and reveals the next rule) and **Why this?** (one line explaining the rule that fired). Below it, up to two "Then" suggestions as small rows.
- **Setup checklist**: shown until complete or dismissed. Items: Connect Moodle, Add timetable, Connect Claude, Add first lecture, Set grade targets. Each opens its route. **Hide checklist** moves it to Connections.
- **Continue** row, unchanged, but opens the Material page.
- **Today timeline**: classes, events, study blocks and deadlines in one time-ordered list with a "now" marker. Every row opens its object: class and study block open the same popover as Calendar, deadline opens the assignment.
- **Next class** folds into the timeline as the highlighted next row with its countdown; the empty state becomes "Add your timetable" linking to Connections › Calendars.
- **Due in the next 7 days**: unchanged, all rows clickable.
- **At a glance** strip: Cards due, Inbox, Claude activity. Each is a button to its route.

### Inbox

The single place for decisions. Changes:

- Badge counts every row shown, including syllabi, briefs and past exams.
- Section headers show counts and a bulk action (**Confirm all**, **Accept all**, **Approve all**).
- Keyboard triage: `↑` `↓` move, `Return` confirms, `⌫` dismisses, `E` edits. Each triage action is undoable.
- **Clear all** becomes soft: one toast with Undo restores everything cleared.
- Rows created by Claude show a small link to the Activity entry that produced them.
- After confirming a file, the toast offers **Open**, which goes to the new Material page.
- Empty state: "Nothing needs a decision" plus the next useful action (usually Add files or the top Next up suggestion).

### Calendar

Keeps the Apple Calendar model. Changes:

- **Month** shows study blocks as small dashed or solid chips and busy time as a faint tint on the day, both controlled by Layers.
- **Agenda** rows open the same popovers as Week.
- **Occurrence popover** gains three links: Course, Assignments for this course, Lecture material (when one is filed for that date).
- **Plan study** proposals appear dashed on the grid with an **Accept all · Review · Dismiss all** bar pinned under the toolbar until resolved.
- Empty week: "No classes this week" plus **Add timetable** or **Plan study**, whichever applies.

### Assignments

Already the most complete screen. Changes:

- Detail panel becomes a native inspector (resizable, toggled with `⌘⌥I`).
- "Copy check-draft-against-rubric prompt" becomes **Check draft with Claude**, a normal Claude job.
- Linked rubric or brief opens the Material page.
- Empty state: quick add with a live example, plus **Import deadlines from Moodle** or **from a syllabus** when either source exists.

### Courses

Courses move into the sidebar as a list under a Courses heading, so one click opens a course. The course page tabs become: **Overview · Assignments · Materials · Concepts · Notes · Cards**.

- New **Assignments** tab: that course's assignments, same rows as the Assignments screen.
- Materials, Concepts and Cards get sort (date, name, status), filter, and paging instead of hard caps.
- Material rows open the Material page. Row menus shrink to Open file, Move, and Delete; Claude actions live on the Material page.
- Delete course is soft with Undo.
- Empty course: "Add this course's slides" drop zone plus **Link Moodle course** when Moodle is connected.

### Material page (new)

The canonical home for any file. Route: `material/{id}`.

- **Header**: title, course, role (editable), processed state, **Open file**, **Show in Finder**.
- **Lectures and readings**: the study flow as a vertical timeline (Recall, Learn, Write, Test). The next step is expanded with its primary button; done steps collapse to a summary line. Below: concepts from this file, cards from this file, sessions, gap reports.
- **Syllabi and briefs**: extracted deadlines with their confirm state, **Extract deadlines with Claude**, and a link to each resulting assignment.
- **Past exams**: extracted patterns and **Find exam patterns with Claude**.
- Failed or unreadable files show the reason and a fix (Retry, Run OCR (optical character recognition), Remove).

### Study

Becomes a hub for doing the work. Segments: **Today · Lectures · Insights**.

- **Today**: cards due with **Start review**, the lecture most in need of its next step, and any unfinished session.
- **Lectures**: the list on the left, the Material page on the right (same component as above), so syllabi and past exams are reachable too via a filter.
- **Insights**: unchanged content, and each stat links to what drives it (e.g., missed count opens those assignments).
- Empty state: **Add your first lecture** (opens file picker) instead of "Go to Inbox."

### Connections (new, in sidebar)

One screen for everything the app talks to, each with a status dot in the sidebar.

- **Overview**: a card per connection with status (Connected, Syncing, Needs attention, Not connected) and one primary action.
- **Moodle**: the current connected and not-connected states, unchanged in content.
- **Calendars**: import, subscriptions, sync, sources list.
- **Claude**: connection, run mode, Claude Code detection, and the full **Activity history**.
- **Apple Calendar and Reminders**: the export and sync toggles.

### Settings (native window, ⌘,)

Only preferences remain: **General · Study planner · Terms and breaks · Notifications · Appearance · Data and export · Advanced**. Data and export gains **Recently Deleted**. Appearance holds the theme picker. Every section has a route.

### Menu bar extra

- **Next up** row is a button that performs the suggested action.
- **Due soon** rows open the assignment in the main window.
- **Next class** opens its popover in Calendar.
- Optional quick-add field that uses the same parser as Assignments.

### Overlays

- **Review sheet** and **Handwriting sheet** stay as sheets; **Get Claude's review** becomes a Claude job.
- **Command palette** indexes every route: screens, Settings sections, Connections, courses, assignments, all materials (labeled by role), and recent items.
- **Toast** always offers Undo for writes and a **View** link when the result lives on another screen.

## Cross-cutting systems

Five systems sit under every screen: routes, Claude jobs, suggestions, undo, and counts. Building these first makes most screen fixes small.

### Routes and navigation history

One `Route` enum replaces the `Screen` enum. Every button, palette result, menu bar row, notification and toast link navigates by route, and the same routes work as `studytracker://` URLs.

| Route | Opens |
| --- | --- |
| `today` | Today |
| `inbox` / `inbox/{section}` | Inbox, scrolled to a section |
| `calendar/{view}/{date}` | Calendar in Week, Month or Agenda at a date |
| `calendar/occurrence/{id}` | Calendar with that class or study block's popover open |
| `assignments` / `assignment/{id}` | Assignments, optionally with one open in the inspector |
| `course/{id}/{tab}` | A course on a given tab |
| `material/{id}` | Material page |
| `study/{segment}` | Study on Today, Lectures or Insights |
| `review` / `review/course/{id}` | Review sheet, all or one course |
| `connections` / `connections/{moodle, calendars, claude, apple}` | Connections, optionally one connection |
| `activity` / `activity/{jobId}` | Activity panel, optionally one job |
| `settings/{section}` | Settings window at a section |
| `setup/{step}` | First-run setup at a step |

The window keeps a Back/Forward history (`⌘[` / `⌘]`, plus toolbar arrows). Restored selections are now intentional: returning to a screen restores its last route, and the toolbar shows the path (e.g., Courses › HM210 › Materials).

### Claude jobs and Activity

Every Claude task becomes a job with the same lifecycle, whatever runs it.

- **One label per task**: Process with Claude, Extract deadlines with Claude, Find exam patterns with Claude, Check draft with Claude, Review my notes with Claude, Quiz me with Claude. The label never changes with run mode.
- **Run mode** (Connections › Claude): *Automatic*, which runs Claude Code in the background when found, or *Claude Desktop*, which copies the prompt and opens Desktop. A small glyph after the label shows which mode applies.
- **States**: Queued → Running → Done or Failed. In Desktop mode: Handed off → Waiting for Claude → Done. The prompt carries a job id, and MCP writes tagged with that id mark the job Done and attach its results. **Mark done** and **Cancel** cover the case where nothing comes back.
- **Queue**: a second job waits instead of showing an error. Queued jobs can be canceled.
- **Activity panel**: a toolbar button on every screen (spinner while running, badge when a job is waiting on you). Each entry shows task, object, state, time, and a result line with links, e.g., "Added 14 concepts · 22 cards to approve." Actions: Open result, Retry, Copy prompt again. Full history lives in Connections › Claude.

This replaces the sidebar spinner row and Settings › Claude › Last Claude activity.

### Suggestions (Next up)

The code is the source of truth; this table replaces SPEC §7.3. First matching rule wins. Rows marked *new* are proposals.

| Order | Kind | Fires when | Button |
| --- | --- | --- | --- |
| 0 (new) | reconnect | A Moodle or calendar sign-in has expired | Reconnect → `connections/moodle` |
| 1 | finishOverdue | An open assignment is past due | Finish: X → `assignment/{id}` |
| 2 | startAtRisk / keepGoing | Hours needed ≥ 50% of free hours before due, or due ≤ 48 h and not started | Start: X (marks In progress) or Keep going: X |
| 3 | planExam | Exam within 14 days and no planned study block | Plan study for X → proposals in Calendar week |
| 4 | review | ≥ 5 cards due | Review N cards (about M min) → `review` |
| 5 | recall | A processed lecture hasn't been recalled | Recall: lecture → `material/{id}` |
| 6 | process | A filed lecture isn't processed | Process with Claude (job; stays on Today) |
| 7 | approveCards | Proposed cards waiting | Approve N cards → `inbox/cards` |
| 8 | nothing | None of the above | "Nothing urgent." plus a quiet **Plan the week** or **Review ahead** |

**Not now** snoozes that suggestion (its kind plus object) until the next morning, or earlier if its data changes (e.g., the assignment becomes overdue). Setup checklist items dismiss permanently. **Why this?** shows the rule that fired and a **Show snoozed** link.

### Undo and Recently Deleted

- Every delete is a soft delete (`deletedAt` timestamp). Course, term and material deletes cascade and restore together.
- Every write goes through the native undo manager, so `⌘Z` works for the last 20 actions, not only while the toast is visible.
- Clear all in the Inbox is one undoable action.
- Settings › Data and export › Recently Deleted lists items for 30 days with Restore and Delete now. Material files move to the app's own trash folder, not the system Trash, so restore is exact.

### Counts and badges

- Inbox badge = total rows from the same query that builds the Inbox sections.
- Connections sidebar row shows a dot: accent when something needs attention, none when all is well.
- Activity toolbar badge = jobs waiting on you (handed off, failed).
- Dock icon badge (optional, in Notifications settings): overdue plus Inbox.

## Themes

A theme is a named set of tokens with a light and a dark variant. Views never use a raw color, size or radius, only semantic tokens, so any theme restyles the whole app, menu bar extra and sheets included. Appearance is chosen separately: **Match system · Light · Dark**.

### Token layers

1. **Primitives**: each theme's raw palette ramps (neutral 0–100, attention, success, 8 course hues), in light and dark.
2. **Semantic tokens**: the only names views use (table below).
3. **Component tokens**: a few per shared component (e.g., `row.fill`, `card.border`), mapped to semantic tokens so a theme can override one component without touching others.

| Semantic token | Role |
| --- | --- |
| `canvas` | Window background |
| `surface` / `surfaceRaised` | Cards, panels / popovers, sheets |
| `sidebar` | Sidebar background (solid or system material) |
| `textPrimary` / `textSecondary` / `textTertiary` | Body, metadata, placeholders and dimmed past items |
| `hairline` | Borders and dividers |
| `attention` | The one accent: overdue, due ≤ 48 h, class within the hour, expired sign-in |
| `success` | Connected, done, synced; now used by every connection, not only Moodle |
| `course1`…`course8` | Course dots and bars, tuned per theme and mode |
| `focusRing` | Keyboard focus |
| `fontFamily` / `fontScale` | Family per theme; the five sizes 12 / 14 / 16 / 20 / 28 stay |
| `radiusCard` / `radiusRow` | 10 / 7 by default |
| `motionFast` / `motionConnect` | 150 ms / 400 ms; both drop to 0 under Reduce Motion |

The one-accent rule survives: each theme picks its own attention color, and it still means only "needs attention now."

### Starter themes

Starting values, to be tuned against the contrast test below.

| Theme | Character | Light: canvas / text / attention | Dark: canvas / text / attention | Font | Radius (card / row) |
| --- | --- | --- | --- | --- | --- |
| **Paper** (default) | Today's look: minimal, high contrast | #FFFFFF / #111111 / #D93A2B | #0E0E0E / #F2F2F2 / #FF5A47 | SF Pro | 10 / 7 |
| **Graphite** | Cool grays, calm, desk-app feel | #F4F5F7 / #15171A / #E5484D | #16181C / #E8EAED / #FF6369 | SF Pro | 10 / 7 |
| **Library** | Warm paper, bookish | #FAF6EE / #2A2118 / #9B2C2C | #1B1612 / #EDE3D3 / #E0716B | New York headings, SF Pro body | 8 / 6 |
| **Fjord** | Cool blue-gray, soft | #F2F5F8 / #1B2530 / #E4572E | #111820 / #DCE4EC / #FF7A52 | SF Pro Rounded | 14 / 10 |
| **Mono** | Terminal-like, dense | #FFFFFF / #000000 / #A85A00 | #000000 / #FFFFFF / #FFB020 | SF Mono | 2 / 2 |
| **High Contrast** | Accessibility first | #FFFFFF / #000000 / #B00020 | #000000 / #FFFFFF / #FF6B6B | SF Pro, heavier weights | 10 / 7 |
| **Glass** (macOS 26+) | System translucent materials for sidebar, toolbar and popovers | System materials / label / system red | System materials / label / system red | SF Pro | 14 / 10 |

### Implementation

- A `ThemeTokens` struct and a `Theme` type holding `light` and `dark` token sets, injected through `@Environment(\.theme)`. The resolved set follows the current color scheme.
- `Theme.swift` becomes the Paper theme; existing components switch from fixed values to tokens.
- **Settings › Appearance**: theme grid with live mini-previews of Today in both modes, the Match system / Light / Dark control, and a separate **Density** control (Comfortable, Compact).
- A unit test checks every text-on-surface pair in every theme and mode against WCAG (Web Content Accessibility Guidelines) AA: 4.5:1 for body text, 3:1 for large text and course dots. High Contrast targets 7:1.
- Course hues are stored as a palette index, not a color, so switching themes recolors courses consistently.

## Open questions and build order

### Decide before building

- [ ] **Minimum macOS**: stay on 15, or raise to 26 to use system glass materials and newer SwiftUI throughout? Glass is optional on 15 either way.
- [ ] **Sidebar order and shortcuts**: this plan puts Inbox second (⌘1 Today, ⌘2 Inbox, ⌘3 Calendar, ⌘4 Assignments, ⌘5 Study). Keep, or preserve today's numbering?
- [ ] **Plan study proposals**: app-generated blocks show only in Calendar, Claude's show in both Calendar and Inbox. Should both kinds behave the same? yes both should be the same
- [ ] **Desktop-mode job tracking**: needs the MCP tools to accept an optional job id. Acceptable change to the server contract? yes
- [ ] **Snooze length**: next morning, or user-set in Settings › General? next morning default, editable in settings  > general

### Build order

Foundations first, because most screen fixes depend on them.

1. `Route` enum, URL handling, Back/Forward history.
2. Soft delete, undo manager, Recently Deleted.
3. Theme tokens with the Paper theme at visual parity, plus the contrast test.
4. Claude job model, queue, Activity panel.
5. Connections screen and First-run setup.
6. Material page and the Study hub.
7. Screen fixes: Today, Inbox, Calendar, Courses, menu bar.
8. Remaining themes and the Appearance picker.
9. Regenerate SPEC §7 (rules, shortcuts, design constraints) from this doc.
