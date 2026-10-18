import XCTest
@testable import StudyCore

final class TimetablePictureTests: XCTestCase {
    let today = d("2026-10-18")

    /// What Claude returns for a weekly grid with two groups, a dated exam and one unreadable cell.
    let reply = """
    {"readable": true, "term_start": "2026-09-07", "term_end": "2026-12-18", "groups": ["A", "B"], "note": "Thursday 16:00 was unreadable.",
     "classes": [
      {"title": "Fundamentals of Economics", "weekday": 1, "date": "", "start": "09:00", "end": "10:30", "location": "B204", "group": "", "from": "", "to": ""},
      {"title": "Marketing for the Hospitality Industry", "weekday": 3, "date": "", "start": "14:00", "end": "15:30", "location": "A101", "group": "A", "from": "", "to": ""},
      {"title": "Marketing for the Hospitality Industry", "weekday": 4, "date": "", "start": "14:00", "end": "15:30", "location": "A102", "group": "B", "from": "", "to": ""},
      {"title": "Spanish 2", "weekday": 2, "date": "", "start": "11:00", "end": "12:30", "location": "", "group": "", "from": "2026-10-20", "to": "2026-11-10"},
      {"title": "Economics midterm", "weekday": 0, "date": "2026-10-28", "start": "10:00", "end": "12:00", "location": "Hall", "group": "", "from": "", "to": ""},
      {"title": "Broken", "weekday": 9, "date": "", "start": "25:00", "end": "x", "location": "", "group": "", "from": "", "to": ""}
     ]}
    """

    func testReadsAPictureIntoAWeek() async throws {
        let provider = ScriptedProvider(replies: [{ _ in ChatResponse(text: self.reply, usage: Usage(inputTokens: 1800, outputTokens: 600)) }])
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let (s, usage) = try await TimetableReader.read(image: png, mimeType: "image/png", courses: [], today: today,
                                                       recognisedText: "Mon 09:00 ECON B204", provider: provider, model: "sonnet")
        XCTAssertEqual(usage.inputTokens, 1800)
        let sent = provider.requests[0].messages.last!
        XCTAssertTrue(sent.parts.contains { if case .image(let d, "image/png") = $0 { return d == png }; return false }, "the picture goes to Claude")
        XCTAssertTrue(sent.text.contains("Mon 09:00 ECON B204"), "with the text recognised on the Mac as a hint")
        XCTAssertEqual(s.classes.count, 5, "a class with an impossible day or time is dropped")
        XCTAssertEqual(s.groups, ["A", "B"])
        XCTAssertEqual(TimetableReader.classes(s, group: "A").map(\.location), ["B204", "A101", nil, "Hall"], "group A: its own and everyone's")

        let text = TimetableReader.calendar(TimetableReader.classes(s, group: "A"), schedule: s, tz: madrid, today: today,
                                            fallbackEnd: TimetableReader.lastDay(s, fallback: today.adding(days: 112)))
        let week = Timetable.occurrences(try ICS.parse(text), from: d("2026-10-26"), to: d("2026-11-01"), tz: madrid)
        XCTAssertEqual(week.map(\.summary), ["Fundamentals of Economics", "Spanish 2", "Economics midterm", "Marketing for the Hospitality Industry"])
        XCTAssertEqual(week.map { LocalDate($0.start, tz: madrid) }, [d("2026-10-26"), d("2026-10-27"), d("2026-10-28"), d("2026-10-28")])
        XCTAssertEqual(LocalTime(week[0].start, tz: madrid), t("09:00"))
        XCTAssertEqual(week[0].end!.timeIntervalSince(week[0].start), 90 * 60)
        // Weekly classes run from the term's start to its end; Spanish only for its own weeks.
        XCTAssertEqual(Timetable.occurrences(try ICS.parse(text), from: d("2026-09-07"), to: d("2026-09-07"), tz: madrid).count, 1)
        XCTAssertEqual(Timetable.occurrences(try ICS.parse(text), from: d("2026-12-14"), to: d("2026-12-20"), tz: madrid).map(\.summary),
                       ["Fundamentals of Economics", "Marketing for the Hospitality Industry"])
        XCTAssertEqual(Timetable.occurrences(try ICS.parse(text), from: d("2026-12-21"), to: d("2026-12-27"), tz: madrid).count, 0)
    }

    func testWithoutTermDatesClassesStartThisWeek() throws {
        var s = TimetableReader.parse(try JSONValue.parse(Data(reply.utf8)).any)!
        s.termStart = nil
        s.termEnd = nil
        let text = TimetableReader.calendar(s.classes.filter { $0.title == "Fundamentals of Economics" }, schedule: s, tz: madrid, today: today,
                                            fallbackEnd: today.adding(days: 112))
        let events = Timetable.occurrences(try ICS.parse(text), from: d("2026-09-01"), to: d("2027-03-01"), tz: madrid)
        XCTAssertEqual(events.first.map { LocalDate($0.start, tz: madrid) }, d("2026-10-12"), "from this week's Monday")
        XCTAssertEqual(events.last.map { LocalDate($0.start, tz: madrid) }, d("2027-02-01"), "until the fallback end")
    }

    func testAPictureThatIsntATimetable() {
        let s = TimetableReader.parse(["readable": false, "term_start": "", "term_end": "", "groups": [], "note": "This is a photo of a cat.", "classes": []])
        XCTAssertEqual(s?.readable, false)
        XCTAssertEqual(s?.note, "This is a photo of a cat.")
    }

    func testClassesCalendarHoldsExactlyTheTimetable() {
        let a = CalendarMirror.ClassEntry(title: "Economics", start: at("2026-10-19", "09:00"), end: at("2026-10-19", "10:30"), location: "B204")
        let b = CalendarMirror.ClassEntry(title: "Marketing", start: at("2026-10-21", "14:00"), end: at("2026-10-21", "15:30"), location: nil)
        let moved = CalendarMirror.ClassEntry(title: "Economics", start: at("2026-10-19", "11:00"), end: at("2026-10-19", "12:30"), location: "B204")
        let first = CalendarMirror.diff(wanted: [a, b], existing: [:])
        XCTAssertEqual(first.create, [a, b])
        XCTAssertTrue(CalendarMirror.diff(wanted: [a, b], existing: ["e1": a.key, "e2": b.key]) == ([], []), "nothing changed, nothing to do")
        let next = CalendarMirror.diff(wanted: [moved, b], existing: ["e1": a.key, "e2": b.key, "e3": b.key])
        XCTAssertEqual(next.create, [moved])
        XCTAssertEqual(Set(next.delete), ["e1", "e3"], "the old time and a duplicate go")
        let cancelled = Timetable.Instance(uid: "x", summary: "Economics", start: a.start, end: a.end, allDay: false, location: "B204", cancelled: true)
        XCTAssertTrue(CalendarMirror.classEntries([cancelled]).isEmpty, "a cancelled class stays out of the phone's calendar")
    }
}

final class ClaudeCodePictureTests: XCTestCase {
    func testAPictureGoesThroughStreamJSON() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-pic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"{\"readable\":true}","num_turns":1,"usage":{"input_tokens":1500,"output_tokens":90}}"#
        let body = "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"\(dir.path)/args.txt\"\ncat > \"\(dir.path)/stdin.txt\"\n"
            + "cat <<'JSON'\n{\"type\":\"system\",\"subtype\":\"init\"}\n{\"type\":\"assistant\",\"message\":{}}\n\(result)\nJSON\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let p = ClaudeCodeProvider(cli: script, workingDirectory: dir.appendingPathComponent("work"))
        let png = Data([1, 2, 3])
        let r = try await p.send(ChatRequest(model: "sonnet", messages: [.system("Read it."),
                                                                         ChatMessage(role: .user, parts: [.image(png, mimeType: "image/png"), .text("Timetable please.")])]))
        XCTAssertEqual(r.text, #"{"readable":true}"#)
        XCTAssertEqual(r.usage.inputTokens, 1500)
        let args = try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(args[args.firstIndex(of: "--input-format")! + 1], "stream-json")
        XCTAssertEqual(args[args.firstIndex(of: "--output-format")! + 1], "stream-json")
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "", "still no tools")
        let line = try JSONValue.parse(try Data(contentsOf: dir.appendingPathComponent("stdin.txt")))
        XCTAssertEqual(line["type"]?.string, "user")
        let content = line["message"]?["content"]?.array ?? []
        XCTAssertEqual(content.first?["source"]?["data"]?.string, png.base64EncodedString())
        XCTAssertEqual(content.last?["text"]?.string, "Timetable please.")
    }
}

final class WorkViewTests: XCTestCase {
    func testWhatClaudeDoesNextAndWhatItDid() async throws {
        let w = BookWriterTests()
        let store = try BookStore.inMemory()
        let (course, files) = try w.makeCourse(store)
        let clock = TestClock(ISO.parse("2026-10-16T10:00:00Z")!)
        let gate = Gate()
        let seen = Statuses()
        let provider = ScriptedProvider(replies: [w.reply(w.contents(files)), { _ in gate.wait(); return ChatResponse(text: BookWriterTests.chapter("One"), usage: Usage(inputTokens: 1, outputTokens: 1)) }])
        let writer = BookWriter(store: store, engine: { (provider, "sonnet") }, clock: { clock.now }, onChange: { s in seen.add(s) })
        await writer.start()
        try await Task.sleep(nanoseconds: 300_000_000)

        let now = seen.last
        XCTAssertEqual(now?.job, .chapter(id: store.chapters(courseId: course)[0].id), "the status names the job in flight")
        XCTAssertEqual(now?.startedAt, clock.now)
        let next = store.upcomingJobs(limit: 5, now: clock.now, excluding: now?.job)
        XCTAssertEqual(next, store.chapters(courseId: course).dropFirst().map { .chapter(id: $0.id) }, "then the rest, in order")
        XCTAssertEqual(store.chapterTotals().ready, 0)
        XCTAssertEqual(store.chapterTotals().all, 3)

        gate.open()
        await writer.stop()
        XCTAssertEqual(store.recentChapters().map(\.title), ["What marketing is"])
        XCTAssertEqual(store.chapterTotals().ready, 1)
    }
}

final class Statuses: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [BookWriter.Status] = []
    func add(_ s: BookWriter.Status) { lock.withLock { all.append(s) } }
    var last: BookWriter.Status? { lock.withLock { all.last } }
}

/// Holds a scripted reply until the test lets it go.
final class Gate: @unchecked Sendable {
    private let sema = DispatchSemaphore(value: 0)
    func wait() { sema.wait(); sema.signal() }
    func open() { sema.signal() }
}

/// Opt-in: `STUDY_LIVE_PICTURE=/path/to/timetable.png swift test --filter LivePictureTests` reads a real picture with
/// Claude Code (one request on your plan).
final class LivePictureTests: XCTestCase {
    func testReadsAPictureWithClaudeCode() async throws {
        guard let path = ProcessInfo.processInfo.environment["STUDY_LIVE_PICTURE"], let cli = CLIRunner.findClaude() else {
            throw XCTSkip("set STUDY_LIVE_PICTURE to try a real picture")
        }
        let store = try BookStore.inMemory()
        for (i, (name, code)) in [("Fund of Economics", "BHC1-03-045"), ("Mkt for the Hosp Ind", "BHC1-09-158"), ("Spanish 2", "BHE1-02-215"),
                                  ("Fundamentals of Data", "BHC1-06-081"), ("Hosp Fin Accounting", "BHC1-05-069"), ("HR Diversity", "BHC1-08-155"),
                                  ("Communication Skills", "BHC1-02-024")].enumerated() {
            try store.upsertMoodleCourse(moodleId: i + 1, name: name, code: code, start: nil, end: nil, hidden: false)
        }
        let url = URL(fileURLWithPath: path)
        let image = try Data(contentsOf: url)
        let provider = ClaudeCodeProvider(cli: cli, workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("st-live"), timeout: 300, effort: nil)
        let started = Date()
        let (s, usage) = try await TimetableReader.read(image: image, mimeType: "image/png", courses: store.courses(), today: d("2026-10-18"),
                                                       recognisedText: "", provider: provider, model: "sonnet")
        print("LIVE: \(Int(Date().timeIntervalSince(started)))s, \(usage.inputTokens) in, \(usage.outputTokens) out; readable \(s.readable); term \(s.termStart?.string ?? "-") – \(s.termEnd?.string ?? "-"); note: \(s.note)")
        for c in s.classes { print("LIVE: \(c.weekday) \(c.start)-\(c.end) \(c.title) @ \(c.location ?? "-") \(c.group ?? "")") }
        XCTAssertTrue(s.readable)
        XCTAssertFalse(s.classes.isEmpty)
    }
}
