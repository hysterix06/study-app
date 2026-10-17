# Decisions

Deviations from [SPEC.md](SPEC.md) and answers to its **[VERIFY]** / **[DECISION]** items. Newest last.

## D1. Native Swift instead of Tauri + React + Node

**Spec:** Tauri v2 shell, React/TypeScript UI, Node MCP server, shared TypeScript core.

**Chosen:** One Swift package: `StudyCore` (domain logic, SQLite, parsers, prompts), `StudyMCPCore` + `study-mcp` (MCP server), `StudyTracker` (SwiftUI app).

**Why:**
- The review's highest-value additions are all Apple frameworks: Vision (on-device OCR of scanned PDFs, slide pictures and handwriting), PDFKit/CoreGraphics (page rendering, Cornell PDFs), EventKit (Calendar and Reminders sync to iPhone), UserNotifications, the menu bar, Keychain and Continuity Camera. In Tauri each of these needed a Swift helper anyway, which makes three languages.
- One language for app and MCP server means one SQL layer and one set of domain types. Spike A (webview transactions over a pooled `tauri-plugin-sql`) and Spike B (which SQLite library the Node runtime inside Claude Desktop supports) both disappear.
- Rust and pnpm are not installed on this Mac. Xcode and Swift 6.4 are.
- The student's other project (Net Worth) already has a SwiftUI app, and a future iPad companion can reuse `StudyCore`.

**Cost:** No reuse of `ts-fsrs`, `chrono-node` or `ical.js`. Their equivalents are written in Swift and covered by tests (D5–D7).

## D2. Instants stored in UTC ("…Z")

The spec allowed any ISO 8601 offset. Mixed offsets do not sort correctly as text, so `ORDER BY due_at` and range queries would be wrong across daylight-saving changes. Every instant is stored as UTC `YYYY-MM-DDTHH:MM:SSZ`. Class patterns keep local time plus an IANA zone, as the spec requires. The MCP server returns times in the student's zone with an offset.

## D3. Single SQLite writer per process, WAL between processes

Each process opens one connection in WAL mode, with a recursive lock so a transaction can't interleave with statements from another thread. Transactions use `BEGIN IMMEDIATE` so the app and the MCP server never deadlock on a read-to-write upgrade. The app polls `PRAGMA data_version` every 1.5 s and refreshes the UI when Claude writes.

## D4. Schema changes from §4

- **Concepts are course-level** (`UNIQUE(course_id, name)`), with `concept_sources(concept, material, chunk)`. The same concept taught in three lectures is one node with three sources, and links work across lectures.
- **Grading scales and component minimums:** `courses.grade_scale` (percent, 0–10, 0–20, Swiss 1–6), `pass_mark`, and `assignments.min_pass_pct`. Grade math reports `component_failed` and pending minimums.
- **Proposed flashcards:** `cards.status` (`proposed` / `active` / `suspended`). Claude's cards wait for the student to approve or rewrite them, which protects the generation effect.
- **Assessment realism:** assignment kinds `report`, `project`, `case`, `lab`; `group_members`; `rubric_material_id`; material `role` (lecture, reading, syllabus, rubric, brief, past exam).
- **Busy time:** `events.kind = 'busy'` from calendars marked as work or personal. The planner and Today ranking avoid them.
- **Tables the spec implied but did not define:** `conflicts`, `calendar_sources`, `sync_map`, `handwriting_captures`, and `study_sessions.material_id` (which `record_session` needed).
- `assignments.course_id` is nullable only for unmatched proposals. Confirming one requires a course.

## D5. FSRS written in Swift

This is FSRS-5 with its 19 default weights and short learning steps: 1, 5 and 10 minutes for new cards, and 5 or 10 minutes for Again/Hard while learning. There is no interval fuzz, so tests with fixed dates are exact. Intervals keep hard ≤ good < easy. The serialized card is kept in `fsrs_json`, with `due` and `state` mirrored as columns.

## D6. Quick-add parser written in Swift (instead of chrono-node)

`NSDataDetector` can't take a reference date, so it can't be tested deterministically. The hand-written parser covers weekdays (`fri`, `next fri`), `today` / `tomorrow` / `in N days|weeks`, month names in either order, numeric dates (day-first by default, a setting), ISO dates, `5pm` / `17:30` / `noon` / `at 3`, weights, hours or minutes, course codes (also `HM 210`, `#HM210`), aliases, and kind keywords. A course name alone is only a suggestion, and ambiguity opens a picker. The test suite has 33 phrases.

## D7. ICS parser written in Swift (instead of ical.js)

It covers unfolding, escaping, TZID, VALARM skipping, RRULE (WEEKLY with BYDAY/UNTIL/COUNT/INTERVAL, DAILY, MONTHLY, YEARLY), EXDATE and RECURRENCE-ID. Outlook's Windows zone names (e.g. "Romance Standard Time") are mapped to IANA zones. A weekly RRULE with interval 1 becomes one pattern per weekday. Any other rule expands into individual events. Deadline-looking events (including Moodle's "… is due") become proposals, with CATEGORIES used for course matching. A recurring class with no matching course creates a course, shown in the import preview.

## D8. No OCR non-goal reversed

§1.4 excluded OCR and §13.7 said "Claude sees text only". Both assumptions are false: Claude reads images, and Vision OCR is local and free.
- Scanned PDF pages are recognized on import. `needs_ocr` now only means that recognition also failed.
- Slide pictures are extracted, and their text is recognized in the background ("Text in pictures").
- Charts are extracted as data tables.
- `get_slide_images` returns the pictures to Claude as image content.

## D9. Headless processing through Claude Code (optional)

The spec's non-goal was "in-app calls to any AI API", meant to avoid keys and per-call cost. When the `claude` CLI is found (PATH, `~/.local/bin`, or the VS Code/Cursor extension), Process runs `claude -p` with `--mcp-config` pointing at the bundled server, `--strict-mcp-config`, and only the Study Tracker tools allowed. This uses the student's own Claude plan and needs no API key. Copy-paste stays the fallback and remains the only path for conversational sessions (recall, Feynman, quiz).

## D10. Reaching the student

Three things are added because a tracker that only works when opened goes stale:
- **Notifications:** a class 10 minutes before, deadlines 24 hours and 2 hours before, planned study blocks, and a morning digest.
- **Menu bar extra:** next class, suggested action, due soon.
- **One-way EventKit sync:** a "Study Tracker" calendar (iCloud when available) and a Reminders list.

## D11. Today ranking

The ordered rules in §7.3 are kept (first match wins, deterministic, unit-tested), with these changes:
- **Overdue:** the heaviest item wins, not the oldest.
- **At risk:** a new rule ranks work by weight × (hours still needed ÷ free study hours before the deadline), where free hours count classes and busy time.
- **Exam planning:** triggers 14 days out instead of 7, because spacing needs lead time.
- **Recall:** a new rule fires within ~48 hours of a lecture being processed.
- **Approve proposed cards:** a new rule, placed before "Nothing urgent".

## D12. MCP server details

- The server implements MCP JSON-RPC over newline-delimited stdio directly (initialize, tools, prompts, ping). There's no SDK dependency.
- The protocol version echoes the client's request if it's 2024-11-05, 2025-03-26 or 2025-06-18.
- Doubles in tool output are rounded to 3 decimals. Storage keeps full precision.
- New read tools: `get_slide_images`, `get_handwriting_captures`, `get_outcomes`.
- New write tool: `propose_cards` (front ≤ 200, back ≤ 300 characters).
- `save_questions(create_cards: true)` creates *proposed* cards.
- New prompts: `review_handwriting`, `check_draft` (rubric, never rewriting the student's text), `practice_problems` (calculation drills), `exam_patterns`.
- STUDY_RULES now allow real-world examples labelled "(outside the material)" and tell Claude to look at slide pictures.
- Validation errors use a new code, `INVALID_ARGUMENT`. The spec's list had no generic validation code.

## D13. Installing into Claude Desktop

There are two routes, both in Settings → Claude:
1. **Connect:** writes a `study-tracker` entry into `~/Library/Application Support/Claude/claude_desktop_config.json`, pointing at the server inside the app bundle. Other settings are kept and a timestamped backup is made first.
2. **Install as extension:** opens the bundled `study-tracker.mcpb` with Claude Desktop, which registers `.mcpb` and `.dxt` files. The manifest uses `server.type: "binary"`.

**[VERIFY]:** check the manifest against the current MCPB spec with `npx @anthropic-ai/mcpb validate` if the extension route misbehaves. The config route does not depend on it.

## D14. PDF output

Cornell sheets are drawn directly with CoreText into a PDF: A4 or Letter, 15 mm margins, cue rows never split across pages, a summary box and a "look at these yourself" list. Output is deterministic and needs no webview print dialog. Printing goes through PDFKit's print operation.

## D15. Moodle

Moodle is reached through its mobile web service (`login/token.php?service=moodle_mobile_app`, then `webservice/rest/server.php`). It is read-only, and the token lives in the Keychain; the password is used once and never stored. For single sign-on schools (Microsoft 365 and others) the app does what the official app does: it opens `admin/tool/mobile/launch.php` in a web view with no stored cookies, lets the school's own sign-in run, and catches the `moodlemobile://token=<base64 of signature:::token[:::privatetoken]>` redirect. Sites set to log in within the app (`typeoflogin` 1, common with Microsoft 365 through `auth_oidc`) refuse the launch page with `pluginnotenabledorconfigured` unless the session has only just signed in, and the user agent doesn't change that. So on a refusal the web view opens the login page, and when sign-in finishes it swaps the redirect to the dashboard for the launch page before any site page can clear Moodle's "just logged in" flag. Pasting the "Moodle mobile web service" security key still works as a fallback.

Functions used:
- `core_webservice_get_site_info`, `core_enrol_get_users_courses`
- `mod_assign_get_assignments`, `mod_assign_get_submission_status`
- `core_calendar_get_action_events_by_timesort`
- `gradereport_user_get_grade_items`
- `core_course_get_contents` (file downloads go through the normal import pipeline and dedupe)

Moodle deadlines are confirmed directly by default (a setting). User edits are protected with conflicts, as with ICS.

## D16. Things deliberately left out

- **Writing back to Moodle or Outlook.** It's a non-goal, and the risk isn't worth it.
- **An in-app AI API key.** D9 covers the need without one. *Reversed by D17.*
- **An iPad app.** `StudyCore` is ready for one later.
- **Mobile review.** Anki export (.tsv) covers it without building a phone app.

## D17. AI everywhere: built-in engines, any AI app, any chatbot

**Was:** Claude only, through Claude Desktop (MCP) or `claude -p` (D9, D13, D16).

**Now:** one job queue with many engines, and three editions planned (Mac App Store, iOS, and a minimal direct download for macOS, Windows and Linux). New target `StudyAI` holds it all, portable except code behind `canImport`.

- **Built-in engines** (`Provider.swift`): Apple's on-device model, Apple Private Cloud Compute, OpenRouter, Groq, Gemini, Mistral, Ollama (local and cloud), LM Studio, OpenAI, DeepSeek, and Anthropic. One OpenAI-compatible client covers most of them; Anthropic uses raw HTTP (no Swift SDK) and replays assistant turns verbatim so thinking blocks stay valid; Apple's models run tools inside their own session.
- **Free by default.** With no choice made, the app picks Apple's cloud model (App Store builds), then the on-device model, then Claude Code (as before), then any free engine. Apple's cloud model needs the `com.apple.developer.private-cloud-compute` entitlement, which Apple only grants to App Store apps in the Small Business Program, so the direct download can't use it.
- **Pipelines, not agents, for background work** (`Pipelines.swift`). The app reads the lecture, asks for JSON, checks it, and saves through the MCP tools. 2-6 requests per lecture instead of ~20, so free tiers (OpenRouter: 50 a day) and small models work. Measured on this Mac (M2, macOS 27): the on-device model processed a 4-slide lecture in 2 requests and 51 s (4 concepts, 16 questions, 3 cards, a sheet).
- **Same rules for every engine.** In-app engines call the tools through `MCPServer.callTool` in-process (`MCPToolHost`), as audit actor `ai`. Each task gets only the tools it needs (`AITask.toolNames`); all 26 tools overflow the on-device model's 4k context.
- **In-app chat** for recall, quizzes, Feynman, draft checks, practice and handwriting review. Flashcard ratings come from buttons the student taps (an app-only `ask_for_rating` tool); the model never sees `log_review`.
- **Your AI apps** (`Connectors.swift`): one-click connection for Claude Desktop, Claude Code, ChatGPT's Codex tab and the Codex CLI, VS Code with Copilot, Cursor, LM Studio, Windsurf, Copilot CLI and Gemini CLI; guided setup for Zed, Perplexity and others. Order of preference: the app's own CLI or install link, then a strict-JSON edit (key order kept, three backups, commented JSONC files never rewritten), then a snippet. Status is real: the server records each client's name, so cards say "Last used 2 min ago". ChatGPT's normal chat, the Gemini app, Brave Leo and Le Chat can't use a local server; the app says so.
- **Copy for any chatbot** (`PastePrompts.swift`): lecture and syllabus tasks produce a self-contained prompt and import the pasted JSON through the same checks.
- **Consent, money, keys.** Each cloud provider needs the student's agreement once, with a plain data-use label; OpenRouter routes only to providers that don't train unless the student allows it. Gemini's free tier is marked unavailable in the EEA, UK and Switzerland (Google's terms). Paid engines stop at a monthly cap ($5 default); every job stops at 600k tokens. Keys live in the Keychain.
- **MCP server:** dual-era (2026-07-28 `server/discover` and per-request `_meta`, plus `initialize` for 2025-11-25 and earlier), and a new read tool, `get_task_instructions(job)`, because ChatGPT/Codex don't show MCP prompts. MCPB manifest 0.3; one version number in `MCPServer.swift`.

**Deliberately not done:** reverse-engineering consumer chat endpoints (Brave Leo, duck.ai, chatgpt.com) or reusing other apps' OAuth tokens: against their terms, and accounts get blocked. A hosted proxy paying for a free model is left for later (it would be one more provider). Codex and Copilot CLIs are offered as MCP connections, not background runners, until their headless flags are verified. Anthropic's rules for using a Claude plan through `claude -p` changed three times in 2026; Claude Code is labelled as using the student's plan and is never the only engine.

**Open (needs an Apple Developer account and devices):** whether the MCP helper inside a sandboxed App Store build can be launched by Claude Desktop and reach an App Group database (fallback: a separate notarized "Connector" download); PCC quotas in practice; iOS build; Linux/Windows compile of the portable targets.


## D18. Claude plan usage, study notes and built-in diagrams

**Problem:** Opening the app used up a whole Claude plan. When no engine was chosen and Apple Intelligence wasn't available, background tasks ran on Claude Code, and Claude Code ran *as an agent*: `claude -p` read the lecture through the MCP tools, called `get_slide_images`, and saved piece by piece. Each of its 20 or more turns re-sent the whole growing conversation, plus Claude Code's own system prompt, every built-in tool definition and the student's own CLAUDE.md, plugins and skills, on their default model (often Opus). Auto-processing counted Claude Code as free, and after any import it queued *every* unprocessed lecture, not just the new one. Claude Code jobs recorded no token use, so the Activity panel showed nothing.

**Now:**
- **Claude Code runs the same pipeline as every other engine** (`ClaudeCodeProvider`): one `claude -p` per request, prompt on stdin, no tools (`--tools ""`), no MCP servers, its system prompt replaced by ours, `--safe-mode` (no CLAUDE.md, plugins, hooks or skills), `--no-session-persistence`, `--effort low` except on Haiku, and the model the student picks (Sonnet by default; Haiku and Opus offered). A lecture is a few requests about the size of its slides. Flags an older Claude Code rejects are dropped and the run retried. `--bare` was not used: it never reads the subscription login, so it can't use a Claude plan.
- **Exploring tasks** (weekly plan, exam patterns) still let Claude Code drive the tools, now with `--tools Read`, `--max-turns 16`, the chosen model, the same lean flags and an empty working folder.
- **Usage is recorded** for Claude Code jobs (input includes prompt-cache reads and writes, which count toward a plan), the per-job token cap applies to them, and Settings › AI shows the last 7 days.
- **Auto-processing** only queues the files just imported, and Claude Code needs the same opt-in as a paid engine.
- **Slides are condensed on the Mac** before any AI reads them (`MaterialCondenser`): headers and footers repeated on many slides, slide numbers, "Thank you" and "Questions?" slides, repeated agenda slides and long speaker notes go. Chunk ids stay, so citations still work.

**Study notes:** The student asked for organized notes and a starter deck, "only what is necessary from each slideshow, improved and reorganized". The lecture request that already produced concepts, questions and cards now also returns `note_sections` (points of kind point, definition, formula, example or caution, each citing chunks); the Cornell request adds an overview and takeaways. Key terms come from the saved concepts. They are stored as a `summary` note (structure in `data_json`, Markdown in `content_md`), so no migration was needed. New MCP tools: `get_study_notes` (a compact form, a fraction of the slides' size) and `save_study_notes`. Recall, Feynman, practice and handwriting prompts read the notes first and call `get_chunks` only for detail. Course notes are compiled locally from every lecture's notes, with a formula sheet and glossary: no AI request. The starter deck is still proposed (the rule that AI cards are proposals stands) but a lecture's cards can be added to review in one step. Lectures processed before this change get notes through a notes-only run (*Make study notes*, per lecture or for a whole course): one request per part, and it writes nothing but the notes.

This changes the original "never write notes for them to copy" rule. The Cornell sheet stays the student's own, written by hand from memory; the study notes are reference reading for the Learn step, the way a good textbook summary is.

**Diagrams:** A diagram is data (`Diagram`: a `graph` on a 0-10 grid with curves, labelled points with axis guides, shaded areas and shift arrows, or a `flow` of 2-8 steps), not HTML or SVG written by the model. A supply-and-demand graph is about 150 tokens this way instead of thousands, it can't carry scripts, coordinates are clamped, and it follows the theme and dark mode. One layout (`DiagramLayout`) feeds a SwiftUI `Canvas` view in the app and an SVG renderer for exports. Lecture notes can carry a diagram per section (only for models with at least 24k context), and chat replies draw ```diagram blocks inline. Exports embed the SVG.

## D19. Notebook, path, session, review (the v6 redesign)

**Was:** every lecture went through a fixed loop (recall, process into concepts and questions, a printed Cornell sheet filled in and photographed, cards), and everything taught had to be taken from the slides, cited. Studying sat three levels down behind about 20 screens, and files fell back to "lecture".

**Now:** the course's files are signals, and the learning comes from outside them.

- **Notebook first.** Each course is written, start to finish, into the student's own dotted notebook: per topic, the words (definitions, with the course's own wording when its files have it) and the pictures (what to draw and label, plus a reference drawing from a strong model). It's the reading-notes pass: the course becomes familiar and its real size visible before the deep learning starts, and it's what exam prep reviews from. No photos; the student checks their own pages against the guide.
- **Path.** A course builder lays the course out as units of numbered topics in the best order to learn it at university level, shaped by the syllabus, what lectures stress (⚑ cues), past-exam marks and deadlines. Topic ids survive rebuilds, so progress stays with a topic; topics the student started are never dropped ("Also studied"). Prerequisites are kept a DAG.
- **Sessions.** One Start button, chosen by fixed, explainable rules (`NextSession`): notebook pages first, then topics in path order with exam pressure, lectures that have moved past the student, fading topics and weak spots. Four kinds: Notebook, Topic (warm-up cards → lesson → the course's own problems → explain it back → keep cards), Review, and Exam prep (cover the page, recall, check, rate solid or shaky; then exam-style practice), each in quick, standard or deep sizes, saved after every step.
- **Mastery** comes only from the student's own ratings and their cards' FSRS retrievability: new → familiar (page written) → learning → practised → solid, and back to refresh when it fades.
- **Two zones.** General teaching (the idea, worked examples, definitions) comes from the model's knowledge and is labelled as such. Anything about what *this course* says must cite its chunks, and a course wording must actually appear in the slide it cites; otherwise it's kept as general knowledge.
- **Files sort themselves.** Rules in several languages (names, Moodle sections and modules, first pages), then free AI for the unsure ones, then the student only below 0.6 confidence. Groups: shapes your path, practice (problems split out word for word, solutions paired by number), exams, course info, not used.

**AI tiers.**

| Tier | Runs on | Does |
| --- | --- | --- |
| Everyday AI (bulk lane) | on-device → Apple cloud → local → free online | sorting files, reading syllabi, labelling problems |
| Everyday AI (quality lane) | Apple cloud → free online → on-device → local | basic path, notebook and lessons; answer checks, explanation feedback and the tutor (never the on-device model: in testing it marked right answers wrong with invented maths) |
| Course builder | Claude Code (`claude -p`, no tools: the course goes in the prompt) → Anthropic key (same prompts); or by hand: Claude Desktop, Copy for Claude.ai | the full path, the notebook guide with drawings, lessons |

Without a course builder, free AI builds a basic version: on a small model, one request per lecture names the ideas it teaches and the app lays them out in teaching order (one request for the whole course on bigger models). With no AI at all, a skeleton path (one topic per lecture, slide headings as words to look up) still works. The builder runs only when the student opts in (setup, Settings, or "Build with Claude" on a course); a plan limit pauses it until the reset time it reports, and free AI carries on meanwhile.

**The builder sends the course, not a tool loop (merged with D18).** A full step (lay out the course, write notebook pages, write lessons) is the same prompt *Copy for Claude.ai* gives the student: about 60,000 characters of course signals for a path, or 12,000 per topic, with four notebook pages or three lessons per request so each answer stays well inside the output limit. It goes to Claude Code through D18's `ClaudeCodeProvider` (stdin, `--tools ""`, no MCP servers, `--safe-mode`, `--no-session-persistence`, `--max-turns 2`, the model picked in Settings › AI, Claude Code's default effort) or to an API key, and the answer is saved through the same checks as a pasted one. Usage is recorded and capped at 1.5M tokens a job; a plan limit pauses the builder until the reset time it reports. The trade-off: the model can no longer open a slide for a closer look, so it sees only what the prompt carries. **Found while verifying the earlier tool route:** Claude Code negotiates MCP protocol 2026-07-28, which requires `ttlMs` and `cacheScope` on list results; without them it dropped every Study Tracker tool. The server still sends both, for Claude Desktop and other MCP clients.

**Rendering:** notebook pages are native SwiftUI (`NotebookPageView`), because they're what the student copies by hand: dotted paper, the words (short maths in a definition becomes Unicode with real sub- and superscripts, `InlineMath`), the pictures and the formulas, typeset by SwiftMath (MIT, its fonts under the GUST and OFL licences). A picture's reference drawing is data when it's a graph or a process (D18's `Diagram`, drawn by the app in the theme's colours, about 150 tokens instead of thousands) and a sanitised SVG otherwise (a labelled structure), drawn by the system as a template image in the theme's pictures colour; when a model sends both, the data is kept. Free AI on models with 24k context or more may add graphs and processes to basic pages too. Lessons, which are long Markdown with maths, stay in LessonKit: marked and KaTeX bundled in the app (MIT), in a web view with a strict CSP, a private `lessonkit:` scheme serving only its own folder, no persistent storage and links that ask first; printing the notebook guide goes through it as well (data diagrams as SVG). Drawings pass `SVGSanitizer` (an element and attribute whitelist; colours become `currentColor`). SwiftMath finds its fonts through SwiftPM's `Bundle.module`; `build-app.sh` copies its bundle into `Contents/Resources` and stops if SwiftPM generated the older accessor that looks at the bundle root (which can't be signed).

**Removed from the app (data kept, still exported):** Today, Inbox, the Study hub and Insights; per-lecture processing; Cornell sheets and their PDF renderer; handwriting photos and their check; the per-task engine pickers; the Activity popover (job history is under Settings › AI). From D18: per-lecture study notes (`get_study_notes`, `save_study_notes`, the Notes tab; definitions and diagrams live in the topic notebook) and Claude Code's tool-driving run. Kept from D18: `ClaudeCodeProvider`, usage tracking, `MaterialCondenser` (now also before deadline reading) and the `Diagram` engine. Old links (`today`, `inbox/…`, `material/…`, `connections/…`, old course tabs) open their new homes.

**Schema v6:** the migration runner turns foreign keys off outside the transaction and checks `foreign_key_check` before committing, so rebuilding `materials` can't cascade-delete chunks; the database is backed up before migrating. Verified on a copy of a real database (261 files): every count kept.

**Open:** a full course build with Claude Code on a real course (the tool-loop attempt hit the plan's session limit; the one-shot route is checked only with scripted engines so far); quality of basic notebook pages on the on-device model (definitions good, formulas sometimes invented); the App Store builder route (D17's sandboxed helper question).

## D20. Back to basics: a book per course and a week that fills itself

**Was (v6, D19):** a notebook guide, topic paths, guided sessions, mastery ratings, exam prep, a practice bank, file sorting with "Needs a look", 12 AI engines and connectors to other AI apps: about 29,000 lines and 42 tables. On the student's own data, none of it was used. 8 courses produced 379 topics and 230 notebook pages, with **0** card reviews, **0** practice attempts and **0** pages marked written. The calendar had 0 classes. The one thing worth reading, a single lesson written by Claude, covered 1 topic out of 379.

**Why it failed:** the AI budget went on scaffolding (sorting, splitting, short definition pages) instead of anything worth reading; studying meant about 25 places to rate or decide something; content was squeezed into fixed slots; topics were too small (41–57 a course, where syllabi list 8–14); the good content needed opt-ins; and the calendar wasn't automatic.

**Now:** the app does three things, and using it should be almost too simple.

- **A book per course.** One request plans the book from the syllabus plus the titles and headings of the lecture files (JSON: 6–16 chapters with syllabus refs and teaching weeks; `is_course: false` hides orientation pages). One request per chapter returns plain Markdown of 3,000–5,000 words in a fixed house style: plain titles, terms defined on first use, real examples with numbers, `:::course` boxes only where the course files support them, figures as `Diagram` data or simple SVG, a *Check yourself* section and 8–12 flashcards. The model teaches from its own knowledge; the course files set scope, order and vocabulary. Chapters are read in a web view (marked and KaTeX, the private `bookkit:` scheme, strict CSP) in **Read** or **Present** (one section or summary per slide).
- **The writer** (`BookWriter`, an actor) does one job at a time: the chapter the student opened, then missing tables of contents, then this week's chapters and the next one (week 1 is the newest course's start date), then later ones, then earlier ones. A plan limit pauses it until the reset time, and the pause survives a relaunch; network errors back off 1, 5 and 15 minutes; two failures mark a job failed until *Try again*. Engines: Claude Code (`claude -p`, no tools, Sonnet by default) or an Anthropic key (Opus 5.5, streamed). Nothing runs before the student chooses one. Measured on real courses: a table of contents is about 5k tokens in and 1k out; a chapter is about 5–7k in and 6–11k out, 50–80 s on Sonnet.
- **The week.** Moodle deadlines (synced at launch and every 3 hours) and classes from a timetable link (Outlook's published ICS, refreshed every 30 minutes) or calendars on the Mac, by day. Cancelled classes stay, struck through. Classes take their course's colour by name, code or book title, and never create courses. Deadlines can be copied into an Apple Calendar calendar the app owns. Moodle's own calendar export is recognised and explained: it holds the deadlines already synced and no classes.
- **Flashcards** from a chapter join review when the student reaches its end. The only rating is *Forgot* or *Got it* (FSRS Again or Good, with no 10-minute learning step for a card got right the first time); a forgotten card returns at the end of the sitting.

**Cut:** the notebook, paths, sessions, mastery, exam prep, practice, file sorting, chat and tutor, the free and on-device engines, Apple Intelligence, the MCP server and connectors, paste routes, editing schedules, the planner, grades, notifications, the menu bar item, themes and exports. The old app is tagged `v6-final`. The new database is `book.db` (schema v1, 7 tables); the old `study.db` is never opened.

**Simplicity rules** (the test for anything added later): setup is three steps (Moodle, Claude, timetable); Home has at most one button (*Review N cards*); the only rating is Forgot or Got it; no badges, notifications or inbox; this week's chapter is ready before the week starts.

**Open:** real classes from an Outlook link (the student's school link wasn't available yet); the calendar copy and Calendar reading in the real app; a friend installing on a clean Mac (the app is signed with an Apple Development certificate, not notarized, so it needs *Open Anyway* once per version).
