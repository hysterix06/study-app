# Study Tracker

A Mac app that turns each of your courses into a textbook written by Claude, and fills in your week on its own.

- **A book per course.** It reads your syllabus and lecture files from Moodle and has Claude write a book of about 8 to 14 chapters, one per topic, in plain language. This week's chapter is written first. Read it like a book, or press **P** to flip through it as slides.
- **Your week.** Classes from your timetable and deadlines from Moodle, day by day. Cancelled classes are struck through.
- **Flashcards.** Finish a chapter and its flashcards join your reviews. Space shows the answer; ← for *Forgot*, → for *Got it*.

There's nothing to set up beyond three steps, and nothing to rate except *Forgot* or *Got it*.

## Install

You need macOS 15 or later.

1. Download **Study Tracker 3.0.0.zip** from [Releases](https://github.com/hysterix06/study-app/releases), unzip it and drag **Study Tracker** to Applications.
2. Open it. macOS says it can't check the app, because it isn't notarized. Open **System Settings › Privacy & Security**, scroll down and press **Open Anyway**. You only do this once per version.

## Set up

Home walks you through three steps:

1. **Moodle.** Type your school's Moodle address (for example `elearning.yourschool.edu`) and sign in on your school's own page. Your courses and deadlines arrive, and the course files are read in the background (a first read can take an hour or two).
2. **Claude.** Choose what writes the books:
   - **Claude Code**, if it's installed and signed in on your Mac ([claude.com/code](https://claude.com/code)). It uses your Claude plan: roughly 150,000–200,000 tokens per course, spread over days, with this week's chapter first. If you hit your plan's limit, writing pauses until it resets.
   - **An Anthropic API key**, charged to your account: roughly $2–3 per course with Claude Opus 5.5.
3. **Timetable.** In Outlook on the web, open **Settings › Calendar › Shared calendars**. Under *Publish a calendar*, choose your calendar and **Can view all details**, press **Publish**, and copy the **ICS** link into Study Tracker. Your classes refresh every half hour. If your school's calendar is already in the Calendar app on your Mac, you can pick it there instead. (Moodle's own calendar link won't work here: it holds your deadlines, which the app already has, and no class times.)

Settings has the rest: sign out of Moodle, change the model or stop writing books, change the timetable, show hidden courses, and copy your deadlines into a calendar so your phone has them.

## Your data

Everything stays on your Mac in `~/Library/Application Support/StudyTracker`, with a backup each day for the last seven days.

| What | Where it goes |
| --- | --- |
| Moodle sign-in | Your password goes only to your school's page. The app keeps a Moodle token in the Keychain. |
| Course files | Read on your Mac. The original files aren't kept, only their text, up to 60,000 characters each. |
| Writing a chapter | The syllabus, the chapter list and excerpts from that chapter's files go to Claude, through Claude Code or your API key. Nothing else does. |
| Timetable link | Kept in the Keychain, since anyone with it can read your calendar. |
| Deadlines in Calendar | Only if you turn it on: a calendar called "Study Tracker deadlines". |

## Build it yourself

You need Xcode with Swift 6.

```sh
swift test                          # the tests
scripts/build-app.sh                # dist/Study Tracker.app and a zip to share
scripts/build-app.sh --install      # the same, installed to /Applications
```

The app signs with your Apple Development certificate if you have one (run `scripts/trust-signing-key.sh` once so codesign stops asking for your password), or ad hoc otherwise. `STUDY_ROOT` and `STUDY_DB_PATH` point the app at another folder and database, for trying things without touching your own.

| Folder | What's in it |
| --- | --- |
| `Sources/StudyCore` | Moodle sync, file reading, the book writer and its prompts, chapters, flashcards (FSRS), the timetable, the database |
| `Sources/StudyTracker` | The app: Home, the book and chapter screens, review, settings |
| `Resources/Book` | The chapter page (HTML, CSS and JavaScript, with marked and KaTeX bundled) |
| `docs/decisions.md` | Why things are the way they are |
