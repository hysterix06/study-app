# Study Tracker

**Learn each course the best way to learn it, and walk into every exam ready.**

Your classes arrive in pieces: deadlines on Moodle, lectures as slide decks, problem sets, past exams, a syllabus somewhere. Study Tracker sorts all of it on its own and turns it into one plan: write the course into a notebook, learn it topic by topic in the best order, and review before you forget. Opening the app shows one button: **Start**.

It's a native macOS app. It's local-first, works without AI, and doesn't need an account.

## How it works

1. **Your notebook first.** Each course is written, start to finish, into your own dotted notebook: per topic, the words (definitions, with your course's own wording when its slides have it) and the pictures to draw. It takes about five minutes a page, and it shows you the whole course isn't that big. Later it's what you revise from.
2. **A path through the course.** Each course is laid out as units of numbered topics (*2.3 Overbooking*) in the best order to learn it at university level, shaped by what your course stresses, what its exams give marks for, and when things are due.
3. **Guided sessions.** *Start* picks the next session by fixed rules you can see ("Final exam in 9 days · taught Tuesday · 25 min"): your notebook pages first, then topics in order, pulled forward by exams and by lectures that have moved past you. A topic session warms up with due cards, teaches the idea with a worked example and your course's angle, has you practise your course's own problems, explain it back, and keep the cards worth remembering. Quick (10 min), standard (25) or deep (50).
4. **Review and exam prep.** Flashcards come back on an FSRS schedule. Two weeks before an exam, exam prep has you cover each notebook page, recall it, redraw it and rate it *solid* or *shaky*, then practise exam-style questions, shaky topics first.

What sits underneath:

- **Files sort themselves.** Lecture slides shape the path; problem sets, tutorials and class examples become practice (each problem split out word for word, with its solution when the course gave one); past exams show where the marks are; syllabi give deadlines and weights; anything that doesn't belong is set aside. Only files the app is unsure about wait for you, in **Needs a look**.
- **How well you know each topic** comes only from your own ratings: *in your notebook*, *learning*, *practised*, *solid*, and *needs a refresh* when it fades.
- **Two kinds of content, kept apart.** General teaching (explanations, examples) is labelled as general knowledge. Anything about what *your course* says points at the slide it comes from, and the app checks the slide really says it.

## AI: free for the everyday work, strong for building courses

The app works without AI: courses still get a path from your lectures, and sessions, reviews and exam prep all run. AI comes in two parts, set in Settings › AI:

- **Everyday AI**, free: sorts files, reads syllabi and labels practice problems, on your Mac with Apple Intelligence when it can. *Sign in with OpenRouter* adds free online models, which also check your answers, give feedback on your explanations and tutor you in a session. (The on-device model never grades: it isn't reliable enough for that.)
- **Course builder**, strong: lays out each course, writes its notebook guide (with reference drawings) and its lessons. It's Claude: Claude Code on your Mac (it uses your Claude plan, in the background: one request per step with the course in it, no tools and none of your own Claude Code setup, on the model you pick in Settings › AI), an Anthropic API key, Claude Desktop, or *Copy for Claude.ai* and paste the answer back. Without one, free AI builds a basic version.

Your course material only goes to the engine you chose. Online engines ask for your agreement the first time.

## Getting started

### Requirements

- macOS 15 or later
- Xcode with Swift 6, to build the app

There are no prebuilt downloads yet, so you build the app from source.

### Build and install

```sh
git clone https://github.com/hysterix06/study-app.git
cd study-app
scripts/build-app.sh --install     # builds, signs (ad hoc) and copies the app to /Applications
```

| Output | What it is |
| --- | --- |
| `Study Tracker.app` | The app, with the MCP server inside (`Contents/MacOS/study-mcp`). Without `--install` it stays in `dist/`. |
| `dist/study-tracker.mcpb` | The same MCP server packaged as a Claude Desktop extension |

### First run

Setup has four steps, and any of them can be skipped:

1. **Welcome**, with *Try sample data* if you'd like to look around first (a term with a fully built course; remove it in Settings › Data and export).
2. **Your school:** connect Moodle and your courses, deadlines, grades and files come in on their own. No Moodle? Add your courses by name.
3. **AI:** free AI is found and turned on; choose whether Claude builds your courses.
4. **Done:** each course gets its path straight away, and a fuller one as the course builder writes it.

## Everyday use

- **Home:** the next session and its *Start* button, anything urgent, each course's notebook and progress, and what's due this week.
- **A course:** **Path** (the topics and how well you know each), **Notebook** (the whole guide on one page, with *Write next pages*, an index to copy into your notebook, and print or PDF), **Angles** (how the course grades and where its exams give marks), **Files**, and **Deadlines** (grades, deadlines and class times).
- **Schedule:** the calendar (week, month, agenda; drag a class to move it) and assignments. Quick add understands plain text: `Pricing report HM210 fri 5pm 30% 6h`.
- **Needs a look:** files the app wasn't sure about, deadlines to confirm, conflicts with your edits, and AI work that failed.
- **Menu bar:** the next session with *Start*, reviews due, and what's due soon.
- **Optional:** reminders, sync to Apple Calendar and Reminders (so your iPhone sees them), Anki export, and Markdown or Obsidian export (including your notebook guide and lessons).

### Keyboard shortcuts

| Keys | Action |
| --- | --- |
| `⌘↩` | Start the next session |
| `⌘1`, `⌘2`, `⌘3`… | Home, Schedule, then your courses |
| `⌘K` | Command palette (courses, topics, files, actions) |
| `⌘N` | New assignment (quick add) |
| `⌘O` | Import files |
| `⌘⇧R` | Just review (Space shows the answer, `1`–`4` rate it) |
| `⌘T` | In a session: the tutor |
| `Esc` | In a session: close it (your place is saved) |
| `⌘⇧S` | Sync |
| `⌘[` / `⌘]` | Back / forward |
| `⌘Z` / `⌘⇧Z` | Undo / redo |

## Privacy and your data

Everything stays on your Mac. The app doesn't have accounts, analytics or a server. Data only leaves your Mac when you sync with Moodle or a calendar link, or when you send material to an AI engine you chose.

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/StudyTracker/study.db` | The SQLite database |
| `~/StudyTracker/Inbox` | Drop folder, watched while the app is running |
| `~/StudyTracker/Library/<term>/<course>/` | Your original files, filed by course, plus pictures extracted from slides |
| `~/StudyTracker/Backups` | Daily backups (the last 14 are kept), plus one before the AI's first change each session |
| `~/StudyTracker/Export` | JSON and Markdown exports, Anki `.tsv` and `.ics` files |
| `~/StudyTracker/mcp.log` | MCP server log (it never contains secrets) |

Calendar links, the Moodle token and AI keys are stored in the macOS Keychain. AI chats are deleted after 90 days. You can change this in Settings.

## What AI is allowed to do

These rules are enforced in code and apply to every engine and every connected app:

- **AI can't delete anything and can't run SQL.** It can't edit your courses, schedule, confirmed assignments or anything you wrote, and it never changes your notebook marks or progress.
- **What your course says must point at your course's files,** and a definition "in your course's words" must actually be in the slide it cites. Answers pasted from a chatbot go through the same checks.
- **A simpler version never replaces a fuller one:** free AI doesn't overwrite what the course builder wrote.
- **Deadlines and study blocks from AI are proposals** until you confirm them.
- **Every rating is yours:** flashcards, practice problems, explaining it back, exam prep. AI feedback is advice only.
- Paid engines stop at a monthly spending limit that you set. Every AI change is logged; the history is in Settings › AI.
- Setting `STUDY_MCP_READONLY=1` makes the MCP server read-only.

## Development

```sh
swift build                 # the app, MCP server and core
swift test                  # 250+ tests: the v6 migration, file sorting, practice splitting, paths and their merges,
                            # the session scheduler, mastery, sessions, MCP over stdio, AI engines and pipelines, LessonKit
STUDY_LIVE_AI=1 swift test --filter LiveAITests   # also runs real engines (Apple Intelligence) when available
swift run StudyTracker      # runs without bundling (notifications need the .app bundle)
```

| Directory | Contents |
| --- | --- |
| `Sources/StudyCore` | Domain logic, SQLite repositories, parsers and prompts. All SQL lives here. |
| `Sources/StudyMCPCore`, `Sources/study-mcp` | The MCP server |
| `Sources/StudyAI` | AI engines, pipelines, the chat loop and AI-app connectors. Apple-only code is behind `canImport`, so this module stays portable. |
| `Sources/StudyTracker` | The SwiftUI app |
| `Resources/LessonKit` | The lesson renderer (and notebook printing): a page with marked and KaTeX, bundled (no network) |
| `Resources/Licenses` | Licences for bundled third-party code (SwiftMath) |
| `Tests/StudyCoreTests` | Tests and fixtures (sample Outlook, Moodle and shift `.ics` files; PPTX, DOCX and PDF files are generated during tests) |
| `scripts/` | `build-app.sh`; `trust-signing-key.sh`, run once so codesign stops asking for your password on every build; and `make_icon.py`, which generates the app icon from code |

[docs/SPEC.md](docs/SPEC.md) is the original specification. [docs/decisions.md](docs/decisions.md) records every change from it and the reason for each one; D18 is the notebook-first redesign.

### Roadmap

Planned: a Mac App Store version, an iPhone app, and a minimal download for macOS, Windows and Linux.
