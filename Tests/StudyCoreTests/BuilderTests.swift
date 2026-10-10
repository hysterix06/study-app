import XCTest
@testable import StudyCore
@testable import StudyMCPCore
@testable import StudyAI

/// The course builder's interface: what it reads, what it saves (and at which tier), when its jobs are finished, and
/// the order the app asks for the work in.
final class CourseBuilderTests: XCTestCase {
    var store: StudyStore!
    var server: MCPServer!
    var ids: (term: Int, hm: Int, mkt: Int)!
    var lecture: Int!
    var chunks: [Int] = []

    override func setUpWithError() throws {
        store = try makeStore(file: true)
        ids = try seedCourses(store)
        let deck = try FixtureFactory.pptx(slides: [
            (title: "Overbooking", bullets: [(0, "Accepting more reservations than rooms, because of no-shows")], notes: "This will be on the exam", picture: nil, table: nil, chart: false),
            (title: "No-show rate", bullets: [(0, "Share of bookings that don't arrive")], notes: nil, picture: nil, table: nil, chart: false),
            (title: "RevPAR", bullets: [(0, "Revenue per available room = ADR × occupancy")], notes: nil, picture: nil, table: nil, chart: false),
        ])
        guard case .imported(let m, _) = store.importMaterial(from: deck, courseId: ids.hm) else { return XCTFail() }
        lecture = m
        chunks = store.chunks(materialId: m).map(\.id)
        server = MCPServer(paths: store.paths, readOnly: false)
    }

    func call(_ name: String, _ args: [String: Any]) -> (isError: Bool, json: [String: Any]) {
        let resp = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])!
        let result = resp["result"] as! [String: Any]
        let text = (result["content"] as! [[String: Any]]).first?["text"] as? String
        return (result["isError"] as? Bool ?? false, (JSON.parse(text) as? [String: Any]) ?? [:])
    }

    func job(_ task: AITask, engine: String, args: [String: String] = [:]) throws -> Int {
        var a = args
        a["course_id"] = "\(ids.hm)"
        let id = try store.enqueueJob(task, args: a, objectKind: "course", objectId: ids.hm, label: task.label, mode: .automatic, engine: engine, courseId: ids.hm)
        try store.setJobState(id, .running)
        return id
    }

    func twoUnits() -> [[String: Any]] {
        [["title": "Capacity", "topics": [
            ["title": "Overbooking", "objectives": ["Explain why hotels overbook"], "emphasis": 3, "sources": [["material_id": lecture!, "chunk_ids": [chunks[0], chunks[1]]]]],
            ["title": "No-shows", "prereqs": ["Overbooking"]],
         ]],
         ["title": "Revenue", "topics": [["title": "RevPAR", "prereqs": ["No-shows"], "sources": [["material_id": lecture!, "chunk_ids": [chunks[2]]]]]]]]
    }

    // MARK: Reading

    func testSignalsShowTheCourseInOneCall() throws {
        let exam = try store.saveAssignment(Assignment(courseId: ids.hm, title: "Final exam", kind: .exam, dueAt: Date().addingTimeInterval(20 * 86_400), weightPct: 60))
        let r = call("get_course_signals", ["course_id": ids.hm])
        XCTAssertFalse(r.isError)
        let lectures = try XCTUnwrap(r.json["lectures"] as? [[String: Any]])
        let outline = try XCTUnwrap(lectures.first?["outline"] as? [String])
        XCTAssertTrue(outline[0].hasPrefix("[\(chunks[0])] slide 1 · Overbooking — Accepting more reservations"), outline[0])
        XCTAssertTrue(outline[0].hasSuffix("⚑"), "the lecturer stressed it in the notes")
        XCTAssertEqual((r.json["deadlines"] as? [[String: Any]])?.first?["assignment_id"] as? Int, exam)
        XCTAssertNil(r.json["current_path"])
        XCTAssertTrue(call("get_course_signals", ["course_id": 9_999]).isError)
    }

    // MARK: Saving, and who wrote it

    func testAPathFromAJobTakesItsTierAndAuthor() throws {
        let basic = try job(.buildPathBasic, engine: "apple.ondevice")
        var saved = call("save_path", ["course_id": ids.hm, "units": twoUnits(), "job_id": basic])
        XCTAssertFalse(saved.isError, "\(saved.json)")
        XCTAssertEqual(store.path(courseId: ids.hm)?.tier, "basic")
        XCTAssertEqual(store.path(courseId: ids.hm)?.builtWith, "Apple Intelligence")
        XCTAssertEqual(store.job(basic)?.state, .done, "saving the path finishes the job")
        XCTAssertEqual((saved.json["topics"] as? [[String: Any]])?.map { $0["number"] as? String }, ["1.1", "1.2", "2.1"])

        let full = try job(.buildPath, engine: "cli.claude")
        saved = call("save_path", ["course_id": ids.hm, "units": twoUnits(), "approach_md": "- Learn the words first", "job_id": full])
        XCTAssertFalse(saved.isError, "\(saved.json)")
        XCTAssertEqual(store.path(courseId: ids.hm)?.tier, "full")
        XCTAssertEqual(store.path(courseId: ids.hm)?.builtWith, "Claude Code")
        XCTAssertEqual(store.job(full)?.resultSummary, "Laid out 3 topics")

        let again = try job(.buildPathBasic, engine: "apple.ondevice")
        let refused = call("save_path", ["course_id": ids.hm, "units": twoUnits(), "job_id": again])
        XCTAssertTrue(refused.isError, "a basic path never replaces the course builder's")
        XCTAssertEqual(refused.json["code"] as? String, "CONFLICT")
    }

    func testANotebookJobFinishesWhenEveryPageIsWritten() throws {
        _ = call("save_path", ["course_id": ids.hm, "units": twoUnits()])
        let topics = store.topics(courseId: ids.hm)
        let unit1 = topics.prefix(2).map(\.id)
        let j = try job(.writeNotebook, engine: "cli.claude", args: ["topic_ids": unit1.map(String.init).joined(separator: ",")])
        let svg = #"<svg viewBox="0 0 100 50"><line x1="0" y1="40" x2="100" y2="10" stroke="red"/><text x="5" y="10">capacity</text></svg>"#
        var r = call("save_notebook", ["course_id": ids.hm, "job_id": j, "pages": [[
            "topic_id": unit1[0],
            "terms": [["term": "Overbooking", "definition": "Selling more rooms than exist, expecting no-shows.",
                       "course_wording": "Accepting more reservations than rooms", "source_chunk_ids": [chunks[0]]]],
            "diagrams": [["title": "Booking curve", "draw": "Bookings rising towards capacity.", "labels": ["capacity"], "svg": svg]],
            "formulas": [["latex": "RevPAR = ADR \\times Occ", "meaning": "Revenue per available room"]],
        ]]])
        XCTAssertFalse(r.isError, "\(r.json)")
        XCTAssertEqual(store.job(j)?.state, .running, "one of two pages: not finished")
        XCTAssertEqual(store.builderProgress(j)?.done, 1)
        r = call("save_notebook", ["course_id": ids.hm, "job_id": j, "pages": [["topic_id": unit1[1], "terms": [["term": "No-show", "definition": "A guest who doesn't arrive."]]]]])
        XCTAssertFalse(r.isError, "\(r.json)")
        XCTAssertEqual(store.job(j)?.state, .done, "every page written")
        XCTAssertEqual(store.job(j)?.resultSummary, "Wrote 2 notebook pages")
        let page = try XCTUnwrap(store.notebook(topicId: unit1[0]))
        XCTAssertEqual(page.tier, "full")
        XCTAssertEqual(page.generatedBy, "Claude Code")
        XCTAssertTrue(page.diagrams[0].svg?.contains("currentColor") ?? false)
        XCTAssertEqual(page.terms[0].locator, "slide 1")
    }

    func testLessonsAndTheTopicView() throws {
        _ = call("save_path", ["course_id": ids.hm, "units": twoUnits()])
        let t = store.topics(courseId: ids.hm)[0]
        let r = call("save_lessons", ["course_id": ids.hm, "lessons": [[
            "topic_id": t.id, "pre_question": "Why sell rooms you don't have?",
            "sections": [["kind": "idea", "title": "The idea", "body_md": "Some guests never arrive, so empty rooms lose money."],
                         ["kind": "course_angle", "title": "Your course's angle", "body_md": "Your course stresses it for the exam.", "source_chunk_ids": [chunks[0]]],
                         ["kind": "course_angle", "title": "Made up", "body_md": "Your course says X.", "source_chunk_ids": [999_999]]],
            "cards": [["front": "Overbooking?", "back": "Selling more rooms than exist, to cover no-shows."]],
        ]]])
        XCTAssertFalse(r.isError, "\(r.json)")
        XCTAssertEqual(store.lesson(topicId: t.id)?.sections.map(\.kind), ["idea", "course_angle"], "an uncited angle is left out")
        let topic = call("get_topic", ["topic_id": t.id])
        XCTAssertFalse(topic.isError)
        let text = try XCTUnwrap(topic.json["course_text"] as? [[String: Any]])
        XCTAssertEqual(text.map { $0["chunk_id"] as? Int }, [chunks[0], chunks[1]], "the slides the path points at")
        XCTAssertNotNil(topic.json["lesson"])
        let path = call("get_path", ["course_id": ids.hm, "unit": 2])
        let units = try XCTUnwrap(path.json["units"] as? [[String: Any]])
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual((units[0]["topics"] as? [[String: Any]])?.first?["number"] as? String, "2.1")
    }

    // MARK: Instructions

    func testBuilderPromptsNameTheirTopicsAndTheJob() throws {
        _ = call("save_path", ["course_id": ids.hm, "units": twoUnits()])
        let topics = store.topics(courseId: ids.hm)
        let path = try Prompts.render("build_course_path", args: ["course_id": "\(ids.hm)", "job_id": "7"], store: store)
        XCTAssertTrue(path.contains("get_course_signals with course_id \(ids.hm)") && path.contains("save_path") && path.contains("job_id: 7"))
        XCTAssertTrue(path.hasPrefix(Prompts.builderRules), "background work: nobody is there to answer")
        let notebook = try Prompts.render("write_notebook", args: ["course_id": "\(ids.hm)"], store: store)
        XCTAssertTrue(notebook.contains("Unit 1: Capacity"), "the next unit without pages")
        XCTAssertTrue(notebook.contains("1.1 Overbooking (topic_id \(topics[0].id))") && !notebook.contains("RevPAR (topic_id"))
        let lessons = try Prompts.render("write_lessons", args: ["course_id": "\(ids.hm)", "topic_ids": "\(topics[2].id)"], store: store)
        XCTAssertTrue(lessons.contains("2.1 RevPAR") && lessons.contains("save_lessons"))
        XCTAssertThrowsError(try Prompts.render("write_notebook", args: ["course_id": "\(ids.mkt)"], store: store), "no path yet")

        let j = try store.enqueueJob(.writeNotebook, args: ["course_id": "\(ids.hm)", "topic_ids": "\(topics[2].id)"], objectKind: "course", objectId: ids.hm,
                                     label: "x", mode: .desktop, courseId: ids.hm)
        try store.setJobState(j, .handedOff)
        let r = call("get_task_instructions", ["job": j])
        XCTAssertFalse(r.isError, "\(r.json)")
        XCTAssertTrue((r.json["instructions"] as? String ?? "").contains("2.1 RevPAR (topic_id \(topics[2].id))"))
    }

    // MARK: The order of the work

    func testTheBuilderLaysOutThenWritesTheNotebookThenLessons() throws {
        XCTAssertEqual(store.nextBuilderStep(courseId: ids.hm, tier: "full")?.task, .buildPath)
        XCTAssertEqual(store.nextBuilderStep(courseId: ids.hm, tier: "basic")?.task, .buildPathBasic)
        XCTAssertNil(store.nextBuilderStep(courseId: ids.hm, tier: "skeleton"), "no AI: the app builds the skeleton itself")

        try store.buildSkeletonPath(courseId: ids.hm)
        XCTAssertEqual(store.nextBuilderStep(courseId: ids.hm, tier: "basic")?.task, .buildPathBasic, "a skeleton is replaced")

        let basicJob = try job(.buildPathBasic, engine: "apple.ondevice")
        _ = call("save_path", ["course_id": ids.hm, "units": twoUnits(), "job_id": basicJob])
        let topics = store.topics(courseId: ids.hm)
        var step = try XCTUnwrap(store.nextBuilderStep(courseId: ids.hm, tier: "basic"))
        XCTAssertEqual(step.task, .writeNotebookBasic)
        XCTAssertEqual(step.topicIds, [topics[0].id, topics[1].id], "the first unit's pages")
        XCTAssertEqual(step.title, "HM210 · Unit 1: Capacity")
        XCTAssertEqual(store.nextBuilderStep(courseId: ids.hm, tier: "full")?.task, .buildPath, "the course builder lays it out again")

        let pages = try job(.writeNotebookBasic, engine: "apple.ondevice", args: step.args)
        for t in topics.prefix(2) {
            _ = call("save_notebook", ["course_id": ids.hm, "job_id": pages, "pages": [["topic_id": t.id, "terms": [["term": t.title, "definition": "d"]]]]])
        }
        XCTAssertEqual(store.job(pages)?.state, .done)
        step = try XCTUnwrap(store.nextBuilderStep(courseId: ids.hm, tier: "basic"))
        XCTAssertEqual(step.topicIds, [topics[2].id], "then the next unit")
        _ = call("save_notebook", ["course_id": ids.hm, "pages": [["topic_id": topics[2].id, "terms": [["term": "RevPAR", "definition": "d"]]]]])

        step = try XCTUnwrap(store.nextBuilderStep(courseId: ids.hm, tier: "basic"))
        XCTAssertEqual(step.task, .writeLessonsBasic, "lessons once the whole notebook guide is written")
        XCTAssertEqual(step.topicIds, topics.map(\.id), "the next three topics to study")
        for t in topics { _ = try store.saveLessons(courseId: ids.hm, [.init(topicId: t.id, sections: [LessonSection(kind: "idea", title: "i", bodyMd: "x")])], tier: "basic", generatedBy: "t") }
        XCTAssertNil(store.nextBuilderStep(courseId: ids.hm, tier: "basic"), "everything written")

        store.markPathStale(courseId: ids.hm)
        XCTAssertNil(store.nextBuilderStep(courseId: ids.hm, tier: "basic"), "new files settle for ten minutes first")
        XCTAssertEqual(store.nextBuilderStep(courseId: ids.hm, tier: "basic", now: Date().addingTimeInterval(700))?.task, .buildPathBasic)
    }

    func testAFailedStepWaitsBeforeTheNextTry() throws {
        let step = try XCTUnwrap(store.nextBuilderStep(courseId: ids.hm, tier: "basic"))
        XCTAssertFalse(store.builderStepFailedRecently(step))
        let j = try job(.buildPathBasic, engine: "apple.ondevice")
        try store.setJobState(j, .failed, error: "nothing to read")
        XCTAssertTrue(store.builderStepFailedRecently(step))
        XCTAssertFalse(store.builderStepFailedRecently(step, now: Date().addingTimeInterval(13 * 3600)), "tried again after half a day")
    }

    func testClaudeCodeRunsWithOnlyStudyTrackerTools() {
        let args = CLIRunner.arguments(prompt: "p", config: "{}")
        let tools = args.firstIndex(of: "--tools")!
        XCTAssertEqual(args[tools + 1], "", "no files, shell or web")
        XCTAssertTrue(args.contains("--strict-mcp-config") && args.contains("--no-session-persistence"))
        XCTAssertFalse(args.contains("Read") || args.contains("--add-dir"))
        XCTAssertEqual(args[args.firstIndex(of: "--allowedTools")! + 1], "mcp__study-tracker")
    }

    func testCourseBuildingTasks() {
        XCTAssertEqual(AITask.buildPath.degradesTo, .buildPathBasic)
        XCTAssertEqual(AITask.writeNotebook.engineLane, .builder)
        XCTAssertEqual(AITask.writeNotebookBasic.engineLane, .quality)
        XCTAssertEqual(AITask.writeLessonsBasic.queueLane, "builder", "even the basic version never holds up new files")
        XCTAssertNil(AITask.writeNotebookBasic.prompt, "the app runs the basic versions itself")
        XCTAssertEqual(ClaudeJob.authorName(engine: "openrouter|qwen:free"), "free AI")
        let onDevice = EngineCandidate(ref: EngineRef("apple.ondevice"), free: true, contextTokens: 8_192, appleOnDevice: true)
        let inputs = EngineResolver.Inputs(ready: [onDevice], cliAvailable: true, builder: .automatic)
        XCTAssertEqual(EngineResolver.candidates(for: .buildPath, inputs), [.claudeCode])
        XCTAssertEqual(EngineResolver.candidates(for: .writeNotebookBasic, inputs), [onDevice.ref], "8k on-device is enough for one page")
    }
}

/// The basic versions, on a scripted free model.
final class BasicBuilderPipelineTests: XCTestCase {
    var store: StudyStore!
    var ids: (term: Int, hm: Int, mkt: Int)!
    var lecture: Int!
    var chunks: [Int] = []

    override func setUpWithError() throws {
        store = try makeStore(file: true)
        ids = try seedCourses(store)
        let deck = try FixtureFactory.pptx(slides: [
            (title: "Overbooking", bullets: [(0, "Accepting more reservations than rooms")], notes: nil, picture: nil, table: nil, chart: false),
            (title: "No-show rate", bullets: [(0, "Share of bookings that don't arrive")], notes: nil, picture: nil, table: nil, chart: false),
        ])
        guard case .imported(let m, _) = store.importMaterial(from: deck, courseId: ids.hm) else { return XCTFail() }
        lecture = m
        chunks = store.chunks(materialId: m).map(\.id)
    }

    func pipelines(_ p: ScriptedProvider, task: AITask) throws -> Pipelines {
        let job = try store.enqueueJob(task, args: ["course_id": "\(ids.hm)"], objectKind: "course", objectId: ids.hm, label: "x", mode: .automatic,
                                       engine: "apple.ondevice", courseId: ids.hm)
        try store.setJobState(job, .running)
        return Pipelines(provider: p, model: "m", host: try MCPToolHost(paths: store.paths, jobId: job), store: store)
    }

    func testABasicPathPointsAtTheLecturesAndExams() async throws {
        let exam = try store.saveAssignment(Assignment(courseId: ids.hm, title: "Midterm", kind: .exam, dueAt: Date().addingTimeInterval(10 * 86_400), weightPct: 30))
        let p = ScriptedProvider(descriptor: testDescriptor(context: 128_000), replies: [{ r in
            let text = r.messages.last!.text
            XCTAssertTrue(text.contains("[1] ") && text.contains("Overbooking · No-show rate"), text)
            XCTAssertTrue(text.contains("[1] Midterm (exam, 30%"))
            return ChatResponse(text: """
                {"approach":["Learn the words first"],
                 "units":[{"title":"Capacity","topics":[
                    {"title":"Overbooking","summary":"Selling beyond capacity.","objectives":["Explain why"],"after":[],"lectures":[1],"emphasis":3},
                    {"title":"No-shows","summary":"Guests who don't come.","objectives":[],"after":["Overbooking"],"lectures":[1, 7],"emphasis":1}]}],
                 "exams":[{"n":1,"topics":["Overbooking"]},{"n":4,"topics":["x"]}]}
                """)
        }])
        let report = try await pipelines(p, task: .buildPathBasic).buildPathBasic(courseId: ids.hm)
        XCTAssertEqual(report.counts["topics"], 2)
        let path = try XCTUnwrap(store.path(courseId: ids.hm))
        XCTAssertEqual(path.tier, "basic")
        XCTAssertEqual(path.approachMd, "- Learn the words first")
        let topics = store.topics(courseId: ids.hm)
        XCTAssertEqual(topics.map(\.title), ["Overbooking", "No-shows"])
        XCTAssertEqual(topics[1].prereqIds, [topics[0].id])
        XCTAssertEqual(store.coverage(topicId: topics[0].id).map(\.materialId), [lecture], "lecture 1, by its number")
        XCTAssertEqual(store.assessmentTopicIds(assignmentId: exam), [topics[0].id])
    }

    func testASmallModelReadsLectureByLectureAndNamesIdeasNotFiles() async throws {
        let second = try FixtureFactory.pptx(slides: [(title: "Walking guests", bullets: [(0, "Service recovery when the hotel is full")], notes: nil, picture: nil, table: nil, chart: false)])
        guard case .imported(let l2, _) = store.importMaterial(from: second, courseId: ids.hm) else { return XCTFail() }
        let c2 = store.chunks(materialId: l2).map(\.id)
        let p = ScriptedProvider(descriptor: testDescriptor(context: 8_192), replies: [
            { [chunks] r in
                XCTAssertTrue(r.messages.last!.text.contains("[\(chunks[0])] Overbooking — Accepting more reservations"))
                return ChatResponse(text: """
                    {"topics":[{"title":"Overbooking","summary":"Selling beyond capacity.","objectives":["Explain why"],"chunks":[\(chunks[0])]},
                               {"title":"Chapter 1 outline","summary":"x","objectives":[],"chunks":[]},
                               {"title":"No-show rate","summary":"Guests who don't come.","objectives":[],"chunks":[\(chunks[1]), 99999]}]}
                    """)
            },
            { r in
                XCTAssertTrue(r.messages.last!.text.contains("Topics from earlier files: Overbooking; No-show rate"), r.messages.last!.text)
                return ChatResponse(text: #"{"topics":[{"title":"Walking guests","summary":"Service recovery.","objectives":[],"chunks":[\#(c2[0])]},{"title":"Overbooking","summary":"again","objectives":[],"chunks":[]}]}"#)
            },
            { _ in ChatResponse(text: #"{"units":["Capacity"],"approach":["Learn the costs first"]}"#) },
        ])
        let report = try await pipelines(p, task: .buildPathBasic).buildPathBasic(courseId: ids.hm)
        XCTAssertEqual(report.requests, 3, "one per lecture, then the unit names")
        let topics = store.topics(courseId: ids.hm)
        XCTAssertEqual(topics.map(\.title), ["Overbooking", "No-show rate", "Walking guests"], "no file names; a repeated idea keeps its first place")
        XCTAssertEqual(store.units(courseId: ids.hm).map(\.title), ["Capacity"])
        XCTAssertEqual(Set(store.coverage(topicId: topics[0].id).map(\.materialId)), [lecture, l2], "taught again: both files are sources")
        XCTAssertEqual(store.coverage(topicId: topics[1].id).first?.chunkIds, [chunks[1]], "only real chunks")
        XCTAssertEqual(store.path(courseId: ids.hm)?.approachMd, "- Learn the costs first")
    }

    func testABasicPageKeepsCourseWordingOnlyWithItsSlide() async throws {
        try store.savePath(courseId: ids.hm, PathInput(units: [.init(title: "U", topics: [.init(title: "Overbooking", sources: [.init(materialId: lecture, chunkIds: [chunks[0]])])])]),
                           tier: "basic", builtWith: "x")
        let topic = store.topics(courseId: ids.hm)[0]
        let p = ScriptedProvider(descriptor: testDescriptor(context: 8_192), replies: [{ [chunks] r in
            XCTAssertTrue(r.messages.last!.text.contains("[chunk \(chunks[0]) · slide 1]"))
            return ChatResponse(text: """
                {"terms":[{"term":"Overbooking","definition":"Selling more rooms than exist.","course_wording":"Accepting more reservations than rooms","chunk":\(chunks[0])},
                          {"term":"No-show","definition":"A guest who doesn't arrive.","course_wording":"Invented wording","chunk":99999}],
                 "diagrams":[{"title":"Booking curve","draw":"Bookings over time, up to capacity.","labels":["capacity"]}],
                 "formulas":[]}
                """)
        }])
        let report = try await pipelines(p, task: .writeNotebookBasic).writeNotebookBasic(courseId: ids.hm, topicIds: [topic.id])
        XCTAssertEqual(report.counts["pages"], 1)
        let page = try XCTUnwrap(store.notebook(topicId: topic.id))
        XCTAssertEqual(page.tier, "basic")
        XCTAssertEqual(page.terms.map(\.courseWording), ["Accepting more reservations than rooms", nil], "made-up wording isn't kept")
        XCTAssertNil(page.diagrams[0].svg, "free AI writes what to draw, not a drawing")
    }

    func testABasicLessonLeavesOutAnUncitedAngle() async throws {
        try store.savePath(courseId: ids.hm, PathInput(units: [.init(title: "U", topics: [.init(title: "Overbooking", sources: [.init(materialId: lecture, chunkIds: [chunks[0]])])])]),
                           tier: "basic", builtWith: "x")
        let topic = store.topics(courseId: ids.hm)[0]
        let p = ScriptedProvider(descriptor: testDescriptor(context: 8_192), replies: [{ _ in ChatResponse(text: """
            {"pre_question":"Why sell rooms you don't have?","idea":"Some guests never come.","example":"100 rooms, 8% no-shows: sell 108.",
             "course_angle":"Your course frames it as a forecast.","angle_chunks":[],"mistakes":"- Ignoring walk costs","summary":"- Overbook by the expected no-shows",
             "checks":[{"prompt":"What's a no-show?","answer":"A guest who doesn't arrive."}],"cards":[{"front":"Overbooking?","back":"Selling more rooms than exist."}],
             "explain_prompt":"Explain overbooking to a new receptionist."}
            """) }])
        let report = try await pipelines(p, task: .writeLessonsBasic).writeLessonsBasic(courseId: ids.hm, topicIds: [topic.id])
        XCTAssertEqual(report.counts["lessons"], 1)
        let lesson = try XCTUnwrap(store.lesson(topicId: topic.id))
        XCTAssertEqual(lesson.sections.map(\.kind), ["idea", "example", "mistakes", "summary"], "no citation, no course angle")
        XCTAssertEqual(lesson.cards.count, 1)
        XCTAssertEqual(lesson.tier, "basic")
    }
}

final class SampleCourseTests: XCTestCase {
    func testTheSampleCourseIsBuiltAndRemovable() throws {
        let store = try makeStore(file: true)
        try SampleData.load(store)
        let hm = try XCTUnwrap(store.courses().first { $0.code == "HM210" })
        XCTAssertEqual(store.path(courseId: hm.id)?.tier, "full")
        let topics = store.topics(courseId: hm.id)
        XCTAssertEqual(topics.count, 6)
        XCTAssertEqual(store.notebooks(courseId: hm.id).count, 6, "the whole notebook guide")
        XCTAssertNotNil(store.notebooks(courseId: hm.id).values.first { !$0.diagrams.isEmpty }?.diagrams.first?.svg, "one reference drawing")
        XCTAssertEqual(topics.filter { store.lesson(topicId: $0.id) != nil }.count, 3)
        XCTAssertEqual(topics.filter(\.inNotebook).map(\.notebookPage), ["2", "3"])
        XCTAssertGreaterThanOrEqual(store.practiceItems(courseId: hm.id).filter { $0.source == "course" }.count, 3, "Tutorial 4, word for word")
        let exam = try XCTUnwrap(store.assignments(AssignmentFilter(courseId: hm.id)).first { $0.title == "Final exam" })
        XCTAssertEqual(store.assessmentTopicIds(assignmentId: exam.id).count, 5)
        XCTAssertNotNil(store.notebook(topicId: topics[3].id)?.terms.last?.courseWording, "the course's own wording, cited")
        try SampleData.remove(store)
        XCTAssertTrue(store.courses().isEmpty)
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM path_topics"), 0, "nothing left behind")
    }
}

extension BasicBuilderPipelineTests {
    func pasteJob(_ task: AITask, args: [String: String] = [:]) throws -> ClaudeJob {
        var a = args
        a["course_id"] = "\(ids.hm)"
        let id = try store.enqueueJob(task, args: a, objectKind: "course", objectId: ids.hm, label: "x", mode: .paste, engine: "paste", courseId: ids.hm)
        try store.setJobState(id, .handedOff)
        return try XCTUnwrap(store.job(id))
    }

    func testCopyForClaudeLaysOutTheCourse() async throws {
        let job = try pasteJob(.buildPath)
        let prompts = try PastePrompts(store: store).prompts(for: job)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("[\(chunks[0])] slide 1 · Overbooking"), "the course's outline with chunk ids")
        XCTAssertTrue(prompts[0].contains("Reply with ONLY a JSON object") && prompts[0].contains(Prompts.pathDesign))
        let answer = """
        Here's the path:
        ```json
        {"approach_md": "- Words first", "units": [{"title": "Capacity", "topics": [
          {"title": "Overbooking", "sources": [{"material_id": \(lecture!), "chunk_ids": [\(chunks[0])]}]},
          {"title": "No-shows", "prereqs": ["Overbooking"]}]}]}
        ```
        """
        let host = try MCPToolHost(paths: store.paths, jobId: job.id)
        let report = try await PastePrompts(store: store).importAnswer(for: job, text: answer, host: host)
        XCTAssertEqual(report.counts["topics"], 2)
        XCTAssertEqual(store.path(courseId: ids.hm)?.tier, "full")
        XCTAssertEqual(store.path(courseId: ids.hm)?.builtWith, "a chatbot")
        XCTAssertEqual(store.job(job.id)?.state, .done, "saving the path finishes the job")
    }

    func testPastedPagesOnlyLandOnTheirTopics() async throws {
        try store.savePath(courseId: ids.hm, PathInput(units: [.init(title: "U", topics: [.init(title: "Overbooking", sources: [.init(materialId: lecture, chunkIds: [chunks[0]])]),
                                                                                       .init(title: "No-shows")])]), tier: "full", builtWith: "x")
        let topics = store.topics(courseId: ids.hm)
        let job = try pasteJob(.writeNotebook, args: ["topic_ids": "\(topics[0].id)"])
        let prompt = try PastePrompts(store: store).prompts(for: job)[0]
        XCTAssertTrue(prompt.contains("(topic_id \(topics[0].id))") && !prompt.contains("(topic_id \(topics[1].id))"))
        XCTAssertTrue(prompt.contains("[chunk \(chunks[0]) · slide 1]"), "the course's own text, citable")
        let answer = """
        {"pages": [{"topic_id": \(topics[0].id), "terms": [{"term": "Overbooking", "definition": "Selling more rooms than exist.",
                     "course_wording": "Accepting more reservations than rooms", "source_chunk_ids": [\(chunks[0])]}]},
                   {"topic_id": \(topics[1].id), "terms": [{"term": "No-show", "definition": "x"}]}]}
        """
        let report = try await PastePrompts(store: store).importAnswer(for: job, text: answer, host: try MCPToolHost(paths: store.paths, jobId: job.id))
        XCTAssertEqual(report.counts["pages"], 1)
        XCTAssertTrue(report.warnings.contains { $0.contains("other topics") })
        XCTAssertNil(store.notebook(topicId: topics[1].id), "an answer for a topic this job didn't ask about is skipped")
        XCTAssertEqual(store.notebook(topicId: topics[0].id)?.terms.first?.courseWording, "Accepting more reservations than rooms")
        XCTAssertEqual(store.job(job.id)?.state, .done)
    }
}
