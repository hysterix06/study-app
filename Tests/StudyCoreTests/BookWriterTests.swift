import XCTest
@testable import StudyCore

final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

final class BookWriterTests: XCTestCase {
    let start = ISO.parse("2026-10-16T10:00:00Z")!

    /// A course with a syllabus and three lectures, all read.
    func makeCourse(_ store: BookStore) throws -> (course: Int, files: [Int]) {
        let c = try store.upsertMoodleCourse(moodleId: 1, name: "Mkt for the Hosp Ind", code: "MKT", start: nil, end: nil, hidden: false).id
        try store.upsertFile(courseId: c, uid: "s", name: "SOW.pdf", section: "Welcome", module: "Scheme of work", position: 0, kind: "syllabus", week: nil,
                             modified: 1, size: 1, text: "Week 1 Introduction. Weeks 2-3 Services. Weeks 4-5 Research.", headings: [], error: nil)
        for (i, t) in ["CH1 Introduction", "CH2 Services", "CH5 Research"].enumerated() {
            try store.upsertFile(courseId: c, uid: "l\(i)", name: "\(t).pptx", section: t, module: t, position: i + 1, kind: "lecture", week: nil,
                                 modified: 1, size: 1, text: "## \(t)\nSlide text for \(t).", headings: [t], error: nil)
        }
        store.markFilesSynced(c)
        return (c, store.files(courseId: c).filter { $0.kind == "lecture" }.map(\.id))
    }

    func contents(_ files: [Int], weeks: [Int] = [0, 0, 0]) -> String {
        JSON.string(["is_course": true, "book_title": "Marketing for the Hospitality Industry", "language": "en", "chapters": [
            ["title": "What marketing is", "summary": "s1", "syllabus_ref": "CH1", "week": weeks[0], "files": [files[0]]],
            ["title": "Services", "summary": "s2", "syllabus_ref": "CH2", "week": weeks[1], "files": [files[1]]],
            ["title": "Market research", "summary": "s3", "syllabus_ref": "CH5", "week": weeks[2], "files": [files[2]]],
        ]])
    }

    /// A chapter long enough to keep.
    static func chapter(_ title: String) -> String {
        let para = String(repeating: "Hotels sell rooms that expire every night, so price and demand matter. ", count: 30)
        let sections = (1...4).map { "## Part \($0)\n\(para)\n\n:::slide\n- point\n:::" }.joined(separator: "\n\n")
        return "# \(title)\n*What this covers.*\n\nOpening.\n\n\(sections)\n\n## Check yourself\n:::check\nQ: Why?\nA: Because.\n:::\n\n```cards\nQ: RevPAR\nA: Revenue per available room.\nQ: ADR\nA: Average daily rate.\n```"
    }

    func reply(_ text: String) -> (ChatRequest) throws -> ChatResponse {
        { _ in ChatResponse(text: text, usage: Usage(inputTokens: 100, outputTokens: 50)) }
    }

    func writer(_ store: BookStore, _ provider: LLMProvider?, clock: TestClock) -> BookWriter {
        BookWriter(store: store, engine: { provider.map { ($0, "sonnet") } }, clock: { clock.now })
    }

    func testWritesTheContentsThenEveryChapterInOrder() async throws {
        let store = try BookStore.inMemory()
        let (course, files) = try makeCourse(store)
        let provider = ScriptedProvider(replies: [reply(contents(files))] + ["One", "Two", "Three"].map { reply(Self.chapter($0)) })
        let w = writer(store, provider, clock: TestClock(start))
        await w.start()
        await w.idle()

        XCTAssertEqual(store.course(course)?.title, "Marketing for the Hospitality Industry", "the book's title replaces Moodle's short name")
        let chs = store.chapters(courseId: course)
        XCTAssertEqual(chs.map(\.title), ["What marketing is", "Services", "Market research"])
        XCTAssertEqual(chs.map(\.status), ["ready", "ready", "ready"])
        XCTAssertEqual(chs.map { ChapterDoc.parse($0.markdown ?? "").title }, ["One", "Two", "Three"], "chapters are written in order")
        XCTAssertNil(chs[0].week, "week 0 means the syllabus didn't say")
        XCTAssertEqual(provider.requests.count, 4)
        XCTAssertNotNil(provider.requests[0].responseSchema, "the contents come back as JSON")
        let firstChapterPrompt = provider.requests[1].messages.last!.text
        XCTAssertTrue(firstChapterPrompt.contains("Write chapter 1: \"What marketing is\""))
        XCTAssertTrue(firstChapterPrompt.contains("Slide text for CH1 Introduction"), "its own lecture is the excerpt")
        XCTAssertFalse(firstChapterPrompt.contains("Slide text for CH2 Services"))
        XCTAssertEqual(provider.requests[1].messages.first?.text, BookPrompts.chapterSystem)

        // Cards wait until the chapter is read.
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM cards WHERE chapter_id = ? AND active = 0", [chs[0].id]), 2)
        store.markRead(chs[0].id, now: start)
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM cards WHERE chapter_id = ? AND active = 1 AND due_at IS NOT NULL", [chs[0].id]), 2)
    }

    func testTheChapterBeingReadComesFirstAndWeeksSetTheOrder() async throws {
        let store = try BookStore.inMemory()
        let (course, files) = try makeCourse(store)
        let provider = ScriptedProvider(replies: [reply(contents(files, weeks: [1, 2, 4]))])
        let w = writer(store, provider, clock: TestClock(start))
        await w.start()
        await w.idle()
        // The scripted engine had nothing more to say, so put the chapters back in the queue.
        try store.db.execute("UPDATE chapters SET status = 'queued', attempts = 0, error = NULL")
        let chs = store.chapters(courseId: course)
        // Term began on 25 September: 16 October is week 4, so "Market research" (week 4) is this week's chapter,
        // then earlier ones, most recent first.
        store.setSetting("term_start", "2026-09-25T00:00:00Z")
        XCTAssertEqual(store.nextJob(now: start), .chapter(id: chs[2].id))
        XCTAssertEqual(store.nextJob(now: start, excluding: [.chapter(id: chs[2].id)]), .chapter(id: chs[1].id))
        XCTAssertEqual(store.nextJob(now: start, focus: chs[0].id), .chapter(id: chs[0].id), "the chapter the student opened wins")
        // Two chapters in the same week are both this week's.
        try store.db.execute("UPDATE chapters SET week = 4 WHERE id = ?", [chs[1].id])
        XCTAssertEqual(store.nextJob(now: start), .chapter(id: chs[1].id))
        XCTAssertEqual(store.nextJob(now: start, excluding: [.chapter(id: chs[1].id)]), .chapter(id: chs[2].id))
        // Without a term start, chapters go in order.
        store.setSetting("term_start", nil)
        XCTAssertEqual(store.nextJob(now: start), .chapter(id: chs[0].id))
    }

    func testAPlanLimitPausesAcrossARelaunchAndThenCarriesOn() async throws {
        let store = try BookStore.inMemory()
        let (course, files) = try makeCourse(store)
        let reset = start.addingTimeInterval(4 * 3600)
        let provider = ScriptedProvider(replies: [reply(contents(files)), { _ in throw AIError.quotaExhausted(message: "Your Claude plan's usage limit is reached.", resetAt: reset) }])
        let clock = TestClock(start)
        let first = writer(store, provider, clock: clock)
        await first.start()
        await first.idle()
        let status = await first.status
        XCTAssertEqual(status.pausedUntil, reset)
        XCTAssertEqual(store.chapters(courseId: course).map(\.status), ["queued", "queued", "queued"], "nothing lost, nothing counted as a failure")
        XCTAssertEqual(store.chapters(courseId: course)[0].attempts, 0)
        await first.stop()

        // Relaunch before the limit lifts: nothing is sent.
        let later = ScriptedProvider(replies: ["One", "Two", "Three"].map { reply(Self.chapter($0)) })
        clock.now = start.addingTimeInterval(3600)
        let second = writer(store, later, clock: clock)
        await second.start()
        await second.idle()
        XCTAssertEqual(later.requests.count, 0)
        await second.stop()

        // After it lifts, the books carry on.
        clock.now = reset.addingTimeInterval(60)
        let third = writer(store, later, clock: clock)
        await third.start()
        await third.idle()
        XCTAssertEqual(store.chapters(courseId: course).map(\.status), ["ready", "ready", "ready"])
    }

    func testAThinChapterIsTriedTwiceThenWaitsForTryAgain() async throws {
        let store = try BookStore.inMemory()
        let (course, files) = try makeCourse(store)
        let thin = reply("# Too short\n\nOne paragraph.")
        let provider = ScriptedProvider(replies: [reply(contents(files)), thin, thin, reply(Self.chapter("Two")), reply(Self.chapter("Three"))])
        let w = writer(store, provider, clock: TestClock(start))
        await w.start()
        await w.idle()
        let chs = store.chapters(courseId: course)
        XCTAssertEqual(chs.map(\.status), ["failed", "ready", "ready"])
        XCTAssertTrue(chs[0].error?.contains("too thin") == true, chs[0].error ?? "")
        provider.replies = [reply(Self.chapter("One"))]
        await w.retry(.chapter(id: chs[0].id))
        await w.idle()
        XCTAssertEqual(store.chapter(chs[0].id)?.status, "ready")
    }

    func testInterruptedWorkGoesBackInTheQueue() throws {
        let store = try BookStore.inMemory()
        let (course, _) = try makeCourse(store)
        store.setTocState(course, "writing")
        store.resetInterrupted()
        XCTAssertEqual(store.course(course)?.tocStatus, "queued")
    }

    func testNothingIsWrittenBeforeAnEngineIsChosen() async throws {
        let store = try BookStore.inMemory()
        _ = try makeCourse(store)
        let w = writer(store, nil, clock: TestClock(start))
        await w.start()
        await w.idle()
        XCTAssertEqual(store.courses().first?.tocStatus, "none")
    }

    func testAnthropicStreamingAssemblesTheText() async throws {
        let t = FakeTransport()
        t.responses = [(200, [:], """
            event: message_start
            data: {"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":30}}}
            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"# Pric"}}
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ing"}}
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}
            data: {"type":"message_stop"}
            """)]
        let p = AnthropicProvider(apiKey: "k", transport: t)
        let got = LockedBox("")
        let r = try await p.stream(ChatRequest(model: "claude-opus-5-5", messages: [.user("x")], maxOutputTokens: 32_000)) { got.value += $0 }
        XCTAssertEqual(r.text, "# Pricing")
        XCTAssertEqual(got.value, "# Pricing")
        XCTAssertEqual(r.usage.inputTokens, 150)
        XCTAssertEqual(r.usage.outputTokens, 42)
        XCTAssertEqual(t.body(0)["stream"]?.bool, true)
        XCTAssertEqual(t.body(0)["output_config"]?["effort"]?.string, "medium")
    }
}
