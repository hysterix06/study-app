# Study Tracker

A local-first macOS app for one hospitality-management student. It does three things:

1. **Know:** your timetable and deadlines, correct and current.
2. **Track:** assignments, weights and grades.
3. **Understand:** lectures become linked concepts, practice questions, flashcards and handwriting-ready Cornell sheets, then spaced repetition keeps them.

Claude does the thinking in your normal Claude Desktop chat, through a small local server (MCP). The app works fully without Claude, and nothing leaves your Mac unless you share it in a conversation.

The original specification is in [docs/SPEC.md](docs/SPEC.md). Every departure from it, and the reason, is in [docs/decisions.md](docs/decisions.md).

## Install

```sh
scripts/build-app.sh --install     # builds, signs (ad hoc) and copies to /Applications
```

The script needs Xcode (Swift 6) and macOS 15 or later. It produces:

| Output | What it is |
| --- | --- |
| `dist/Study Tracker.app` | The app, with the MCP server inside (`Contents/MacOS/study-mcp`). With `--install` it moves to `/Applications` instead, so only one copy is registered. |
| `dist/study-tracker.mcpb` | The same server as a Claude Desktop extension |

## First run

1. **Timetable.** Settings → Calendars → *Import .ics file* (Outlook: File → Save Calendar), or *Subscribe to a calendar link*. Add work shifts as **busy time** so the planner works around them.
2. **Moodle (optional, recommended).** Settings → Moodle. Sign in once, or paste the "Moodle mobile web service" security key if your school uses single sign-on. Deadlines, submission status, grades and new course files then arrive on their own.
3. **Claude.** Settings → Claude → **Connect to Claude Desktop**, then quit and reopen Claude Desktop. If Claude Code is installed (for example through the VS Code extension), *Process* runs in the background with no copy and paste.
4. **Lectures.** Drop PowerPoint, PDF or Word files onto the window, or into `~/StudyTracker/Inbox`. Confirm the course in the Inbox.

To look around first, Today → *Try it with sample data* adds a term, three courses and a lecture. Remove them in Settings → Data.

## How studying works

| Step | What happens |
| --- | --- |
| **Recall** | Copy the recall prompt, brain-dump in Claude, and get a gap report saved back. |
| **Learn** | *Process with Claude* reads every slide, including pictures and charts, and saves concepts that link across lectures, questions, proposed flashcards and a Cornell sheet. |
| **Write** | Print the sheet and fill it by hand from memory. Then *Check my handwritten notes*: photograph it (right-click → Import from iPhone), get a local coverage check, and ask Claude for a real review. |
| **Test** | Native review with FSRS scheduling: Space reveals, keys 1–4 rate. Or quiz in Claude, where you still give your own ratings. |

Study → **Insights** shows whether it's working:

- on-time rate
- 30-day card retention
- recall within 48 hours of processing
- study minutes per week
- grades against targets
- the concepts flagged weak most often

## Everyday use

- **Today** answers "what's next and what's due" with one suggested action, ranked by weight × time pressure.
- **Assignments:** quick add with `Pricing report HM210 fri 5pm 30% 6h`, then press Enter. `⌘N` focuses it.
- **Calendar:**
  - Drag a class to move it and choose *This class only / following / all*.
  - Undo from the toast or `⌘Z`.
  - *Plan study* proposes blocks around classes and busy time.
- **Menu bar** shows the next class, the suggested action and what's due soon.
- **Optional extras:** alerts, Apple Calendar and Reminders sync (Settings → Apple Calendar and alerts), Anki and Obsidian export (Settings → Data).

Keyboard shortcuts:

| Keys | Action |
| --- | --- |
| `⌘1`–`⌘6` | Screens |
| `⌘K` | Command palette |
| `⌘N` | Quick add |
| `⌘⇧R` | Review |
| `⌘⇧P` | Plan study |
| `⌘⇧S` | Sync |
| `T` / `←` `→` | In Calendar: today / previous or next period |

## Where things live

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/StudyTracker/study.db` | SQLite database (WAL; not in a synced folder) |
| `~/StudyTracker/Inbox` | Drop folder, watched while the app runs |
| `~/StudyTracker/Library/<term>/<course>/` | Filed originals and extracted slide pictures |
| `~/StudyTracker/Backups` | Daily copies (14 kept), plus one before Claude's first change each session |
| `~/StudyTracker/Export` | PDFs, JSON/Markdown exports, Anki `.tsv`, `.ics` |
| `~/StudyTracker/Captures` | Photos of your handwritten sheets |
| `~/StudyTracker/mcp.log` | MCP server log (no secrets) |

Calendar links and the Moodle token are stored in the macOS Keychain.

## Safety rules for Claude (enforced in code)

- There are no delete tools and no SQL tool. Claude can't edit courses, schedules, confirmed assignments or anything you wrote.
- Claude can't save a concept or question without source chunks from that material.
- Assignments, study blocks and flashcards from Claude are proposals until you confirm them.
- Flashcard ratings must be yours.
- Every write is audited (Settings → Claude shows the last activity).
- `STUDY_MCP_READONLY=1` registers read tools only.

## Development

```sh
swift build                 # app, MCP server and core
swift test                  # 82 tests: schedule/DST, ICS, quick add, grades, FSRS, Today rules,
                            # planner, parsers (incl. on-device OCR), and MCP integration over stdio
swift run StudyTracker      # run unbundled (notifications need the .app bundle)
```

| Directory | Contents |
| --- | --- |
| `Sources/StudyCore` | Domain logic, SQLite repositories, parsers, prompts. The only place SQL lives. |
| `Sources/StudyMCPCore`, `Sources/study-mcp` | The MCP server |
| `Sources/StudyTracker` | The SwiftUI app |
| `Tests/StudyCoreTests` | Tests and fixtures (Outlook, Moodle and shift `.ics` files; PPTX/DOCX/PDF generated at test time) |
| `scripts/` | `build-app.sh`, `make_icon_svg.py` (the synapse icon is generated from code) |
