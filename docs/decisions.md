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
- **An in-app AI API key.** D9 covers the need without one.
- **An iPad app.** `StudyCore` is ready for one later.
- **Mobile review.** Anki export (.tsv) covers it without building a phone app.
