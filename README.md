# Study Tracker

**Turn messy school material into things you actually understand and remember.**

Your classes arrive in pieces: a timetable in Outlook, deadlines on Moodle, lectures as slide decks, PDFs and Word files. Study Tracker puts all of it in one place, then turns each lecture into a study plan built on how memory works. You recall first, write by hand, test yourself, and review on a spaced schedule. Copying slides isn't part of it.

It's a native macOS app. It's local-first, works without AI, and doesn't need an account.

## What it does

1. **Collects:** Import your timetable, connect your school's Moodle, and drop lecture files onto the window. The app sorts each file into its course, reads it (scanned pages and pictures too, using on-device text recognition) and finds the deadlines in syllabi and assignment briefs.
2. **Organizes:** **Today** shows your next class, what's due, and one suggested next step. You also get a calendar you can edit, assignments with weights and grade math, and a study planner that schedules around your classes and work shifts.
3. **Helps you understand:** Each lecture becomes concepts linked across the whole course, practice questions, proposed flashcards, and a printable Cornell note sheet. A four-step study loop takes you from first exposure to long-term memory.

## How it helps you learn

Each step uses a learning technique that research supports:

| Step | What you do | Why it works |
| --- | --- | --- |
| **1. Recall** | Before reading anything, write down what you remember. The AI compares it with the lecture and saves a gap report. | **Retrieval practice:** pulling information out of memory strengthens it more than re-reading. Seeing your gaps shows you what to focus on. |
| **2. Learn** | *Process lecture* builds concepts, questions and a Cornell sheet. Concepts link to every lecture that teaches them. | **Elaboration:** connecting ideas across lectures builds understanding, not isolated facts. |
| **3. Write** | Print the sheet and fill it in **by hand, from memory**. Then photograph it and get your notes checked. | **Generation effect:** making notes yourself sticks better than reading notes you were handed. The check catches what you missed. |
| **4. Test** | Review flashcards on an FSRS schedule, mixed with cards from other lectures, or take a quiz in the app's chat. | **Spaced repetition** and **interleaving:** reviews come just before you'd forget, and mixed topics teach you to tell ideas apart. |

A few other things support this:

- **The AI proposes flashcards. You approve or rewrite them**, so the cards are in your own words.
- **Explain it back:** explain a concept in plain words and see where your explanation breaks down. This is the Feynman technique.
- **Your ratings are yours:** the AI never grades your recall for you.
- **Insights** show whether your studying is working: on-time rate, 30-day card retention, recall within 48 hours, study minutes per week, grades against targets, and the concepts you get wrong most often.

## AI: your choice, or none

The app works fully without AI. When you want AI, you pick where it runs:

- **Built in and free:** Apple Intelligence on your Mac, or free online models through OpenRouter. API keys for other services (Groq, Gemini, Mistral, OpenAI, Anthropic, DeepSeek) and local engines (Ollama, LM Studio) also work.
- **An AI app you already use:** Claude Desktop, Claude Code, ChatGPT's Codex, VS Code with Copilot, Cursor, LM Studio and others connect in one click through a small local [MCP](https://modelcontextprotocol.io) server that ships with the app.
- **Any chatbot:** *Copy for any chatbot* gives you a ready-made prompt. Paste the answer back and it goes through the same checks.

Your course material is only sent to the engine you chose. Online engines ask for your agreement the first time. Free engines that may train on your data are labeled.

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

A short setup guide opens the first time you launch the app. You can skip any step and come back to it later under **Connections** in the sidebar.

1. **Moodle** (optional): Type your school's Moodle address and sign in on your school's own page. Deadlines, submission status, grades and new course files then sync on their own. If your school doesn't use Moodle, skip this step.
2. **Term:** Name the term and set its start and end dates. You can add breaks later in Settings → Terms and breaks.
3. **Timetable:** Import an `.ics` file (in Outlook: File → Save Calendar) or subscribe to a calendar link. Add work shifts as **busy time** so the planner avoids them.
4. **AI** (optional): If Apple Intelligence is on, it works without setup. *Sign in with OpenRouter* adds free online models, and any AI app on your Mac connects in one click.
5. **Files:** Drop PowerPoint, PDF or Word files onto the window or into `~/StudyTracker/Inbox`, then confirm the course in the Inbox.

To look around first, choose **Explore with sample data** on the welcome screen. It adds a term, three courses and a lecture. To remove them, go to Settings → Data and export.

## Everyday use

- **Today:** answers "what's next and what's due" and suggests one action, ranked by assignment weight and how soon it's due.
- **Inbox:** shows new files, deadlines found in documents, proposed flashcards and study blocks waiting for your OK, and anything that failed to import.
- **Calendar:** has week, month and agenda views. Drag a class to move it, then choose *This class only*, *following*, or *all*. *Plan study* proposes study blocks around your classes and busy time.
- **Assignments:** quick add understands plain text. Type `Pricing report HM210 fri 5pm 30% 6h` and press Enter.
- **Study:** shows today's reviews, every lecture, and Insights. Each file has its own page with the four study steps, its concepts, cards and sessions.
- **Menu bar:** shows the next class, the suggested action and what's due soon.
- **Optional:** reminders, sync to Apple Calendar and Reminders (so your iPhone sees them), Anki export for reviewing on your phone, and Obsidian export.

### Keyboard shortcuts

| Keys | Action |
| --- | --- |
| `⌘1`–`⌘5` | Today, Inbox, Calendar, Assignments, Study |
| `⌘K` | Command palette |
| `⌘N` | New assignment (quick add) |
| `⌘O` | Import files |
| `⌘⇧R` | Start review (Space shows the answer, `1`–`4` rate it) |
| `⌘⇧P` | Plan study blocks |
| `⌘⇧S` | Sync |
| `⌘⇧L` | New AI chat |
| `⌘[` / `⌘]` | Back / forward |
| `⌘Z` / `⌘⇧Z` | Undo / redo |
| `T`, `←` `→` | In the calendar: jump to today, previous or next period |

## Privacy and your data

Everything stays on your Mac. The app doesn't have accounts, analytics or a server. Data only leaves your Mac when you sync with Moodle or a calendar link, or when you send material to an AI engine you chose.

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/StudyTracker/study.db` | The SQLite database |
| `~/StudyTracker/Inbox` | Drop folder, watched while the app is running |
| `~/StudyTracker/Library/<term>/<course>/` | Your original files, filed by course, plus pictures extracted from slides |
| `~/StudyTracker/Backups` | Daily backups (the last 14 are kept), plus one before the AI's first change each session |
| `~/StudyTracker/Export` | PDFs, JSON and Markdown exports, Anki `.tsv` and `.ics` files |
| `~/StudyTracker/Captures` | Photos of your handwritten sheets |
| `~/StudyTracker/mcp.log` | MCP server log (it never contains secrets) |

Calendar links, the Moodle token and AI keys are stored in the macOS Keychain. AI chats are deleted after 90 days. You can change this in Settings.

## What AI is allowed to do

These rules are enforced in code and apply to every engine and every connected app:

- **AI can't delete anything and can't run SQL.** It can't edit your courses, schedule, confirmed assignments or anything you wrote.
- **Every concept and question must cite its source:** the part of the lecture it came from. Answers pasted from a chatbot go through the same check.
- **Assignments, study blocks and flashcards from AI are proposals** until you confirm them.
- **Flashcard ratings come from you.** In the app's chat you tap the rating yourself.
- Paid engines stop at a monthly spending limit that you set.
- Every AI change is logged. Go to Connections → AI to see the activity.
- Setting `STUDY_MCP_READONLY=1` makes the MCP server read-only.

## Development

```sh
swift build                 # the app, MCP server and core
swift test                  # 150+ tests: schedules and daylight saving, ICS, quick add, grades, FSRS, Today rules,
                            # planner, file parsers (including on-device OCR), MCP over stdio, AI engines and pipelines
STUDY_LIVE_AI=1 swift test --filter LiveAITests   # also runs real engines (Apple Intelligence) when available
swift run StudyTracker      # runs without bundling (notifications need the .app bundle)
```

| Directory | Contents |
| --- | --- |
| `Sources/StudyCore` | Domain logic, SQLite repositories, parsers and prompts. All SQL lives here. |
| `Sources/StudyMCPCore`, `Sources/study-mcp` | The MCP server |
| `Sources/StudyAI` | AI engines, pipelines, the chat loop and AI-app connectors. Apple-only code is behind `canImport`, so this module stays portable. |
| `Sources/StudyTracker` | The SwiftUI app |
| `Tests/StudyCoreTests` | Tests and fixtures (sample Outlook, Moodle and shift `.ics` files; PPTX, DOCX and PDF files are generated during tests) |
| `scripts/` | `build-app.sh`, plus `make_icon.py`, which generates the app icon from code |

[docs/SPEC.md](docs/SPEC.md) is the original specification. [docs/decisions.md](docs/decisions.md) records every change from it and the reason for each one.

### Roadmap

Planned: a Mac App Store version, an iPhone app, and a minimal download for macOS, Windows and Linux.
