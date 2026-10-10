import XCTest
@testable import StudyCore
@testable import StudyAI

/// Real engines, opt-in: `STUDY_LIVE_AI=1 swift test --filter LiveAITests`. Skipped otherwise, so the normal suite never
/// depends on a model, a network or Apple Intelligence being enabled.
final class LiveAITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STUDY_LIVE_AI"] == "1", "Set STUDY_LIVE_AI=1 to run live engine tests.")
    }

    func testAppleOnDeviceSortsFilesAndLabelsPractice() async throws {
        #if canImport(FoundationModels)
        let a = AppleProviders.availability(Catalog.appleOnDevice)
        try XCTSkipUnless(a.available, a.reason ?? "Apple Intelligence unavailable")
        let store = try makeStore(file: true)
        let ids = try seedCourses(store)
        let unsure = FixtureFactory.textPDF(pages: ["Hotel operations. Front office procedures for check-in, room assignment and guest folios."], name: "doc_17.pdf")
        let sheet = FixtureFactory.textPDF(pages: ["""
            Exercise 1: A hotel has 200 rooms. 160 are sold at an average rate of 120. Calculate occupancy, ADR and RevPAR.
            Exercise 2: Explain why a hotel might overbook on a Tuesday in March.
            Exercise 3: Compare RevPAR and GOPPAR as measures of performance.
            """], name: "Tutorial 4.pdf")
        guard case .imported(let u, _) = store.importMaterial(from: unsure, courseId: ids.hm),
              case .imported(let t, _) = store.importMaterial(from: sheet, courseId: ids.hm) else { return XCTFail() }
        let provider = try AppleProviders.make(Catalog.appleOnDevice)
        let pipelines = Pipelines(provider: provider, model: "system", host: try MCPToolHost(paths: store.paths), store: store)
        var start = Date()
        let sorted = try await pipelines.sortFiles(materialIds: [u]) { print("progress:", $0) }
        print("sort: \(sorted.requests) requests in \(Int(Date().timeIntervalSince(start))) s → \(store.material(u)!.role) (\(store.material(u)!.sortReason ?? ""))")
        XCTAssertEqual(store.material(u)?.roleSource, "ai")
        start = Date()
        let labelled = try await pipelines.labelPractice(materialId: t) { print("progress:", $0) }
        print("labels: \(labelled.requests) requests in \(Int(Date().timeIntervalSince(start))) s")
        for i in store.practiceItems(materialId: t) { print(" #\(i.number ?? "?") \(i.kind) d\(i.difficulty) \(i.topicLabel ?? "")") }
        XCTAssertEqual(labelled.counts["problems"], 3)
        #else
        throw XCTSkip("No FoundationModels")
        #endif
    }

    /// The basic course build on the on-device model: a path, the first unit's notebook pages and one lesson. Uses a
    /// copy of the database at STUDY_LIVE_DB (course STUDY_LIVE_COURSE) when given, else the sample's marketing course.
    func testAppleOnDeviceBuildsABasicCourse() async throws {
        #if canImport(FoundationModels)
        try XCTSkipUnless(AppleProviders.availability(Catalog.appleOnDevice).available)
        let env = ProcessInfo.processInfo.environment
        let store: StudyStore
        let courseId: Int
        if let source = env["STUDY_LIVE_DB"] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-live-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: dir.appendingPathComponent("study.db"))
            store = try StudyStore.open(paths: AppPaths(database: dir.appendingPathComponent("study.db"), root: dir.appendingPathComponent("files")))
            courseId = Int(env["STUDY_LIVE_COURSE"] ?? "") ?? store.courses()[0].id
            try store.db.execute("DELETE FROM course_paths WHERE course_id = ?", [courseId])
            print("re-sorted \(store.resortFiles()) files, as the app does at launch")
        } else {
            store = try makeStore(file: true)
            try SampleData.load(store)
            courseId = try XCTUnwrap(store.courses().first { $0.code == "MKT201" }).id
        }
        let provider = try AppleProviders.make(Catalog.appleOnDevice)
        func pipelines(_ task: AITask) throws -> Pipelines {
            let job = try store.enqueueJob(task, args: ["course_id": "\(courseId)"], objectKind: "course", objectId: courseId, label: "live", mode: .automatic,
                                           engine: "apple.ondevice", courseId: courseId)
            try store.setJobState(job, .running)
            return Pipelines(provider: provider, model: "system", host: try MCPToolHost(paths: store.paths, jobId: job), store: store)
        }
        var start = Date()
        let path = try await pipelines(.buildPathBasic).buildPathBasic(courseId: courseId) { print("progress:", $0) }
        print("path: \(path.requests) request(s) in \(Int(Date().timeIntervalSince(start))) s · \(path.summary) \(path.warnings)")
        let numbers = store.topicNumbers(courseId: courseId)
        for t in store.topics(courseId: courseId) {
            print(" \(numbers[t.id] ?? "") \(t.title) [e\(t.emphasis)] ← \(t.prereqIds) · files \(store.coverage(topicId: t.id).map(\.materialId))")
        }
        XCTAssertEqual(store.path(courseId: courseId)?.tier, "basic")
        let step = try XCTUnwrap(store.nextBuilderStep(courseId: courseId, tier: "basic"))
        XCTAssertEqual(step.task, .writeNotebookBasic)
        start = Date()
        let pages = try await pipelines(.writeNotebookBasic).writeNotebookBasic(courseId: courseId, topicIds: Array(step.topicIds.prefix(3))) { print("progress:", $0) }
        print("pages: \(pages.requests) requests in \(Int(Date().timeIntervalSince(start))) s · \(pages.summary) \(pages.warnings)")
        for id in step.topicIds.prefix(3) {
            guard let page = store.notebook(topicId: id) else { continue }
            print(" — \(store.topic(id)!.title)")
            for t in page.terms { print("   \(t.term): \(t.definition)\(t.courseWording.map { " | course: \($0) (\(t.locator ?? ""))" } ?? "")") }
            for d in page.diagrams { print("   [draw] \(d.title): \(d.draw) · \(d.labels)") }
            for f in page.formulas { print("   [formula] \(f.latex) — \(f.meaning)") }
        }
        XCTAssertGreaterThan(pages.counts["pages"] ?? 0, 0)
        start = Date()
        let lesson = try await pipelines(.writeLessonsBasic).writeLessonsBasic(courseId: courseId, topicIds: [step.topicIds[0]]) { print("progress:", $0) }
        print("lesson: \(lesson.requests) request(s) in \(Int(Date().timeIntervalSince(start))) s · \(lesson.summary) \(lesson.warnings)")
        for s in store.lesson(topicId: step.topicIds[0])?.sections ?? [] { print("   [\(s.kind)] \(s.bodyMd.prefix(300))") }
        XCTAssertEqual(lesson.counts["lessons"], 1)
        #else
        throw XCTSkip("No FoundationModels")
        #endif
    }

    func testAppleOnDeviceChecksAnswersAndExplanations() async throws {
        #if canImport(FoundationModels)
        try XCTSkipUnless(AppleProviders.availability(Catalog.appleOnDevice).available)
        let store = try makeStore(file: true)
        let p = Pipelines(provider: try AppleProviders.make(Catalog.appleOnDevice), model: "system", host: try MCPToolHost(paths: store.paths, allowed: []), store: store)
        let problem = "A 100-room hotel sold 82 rooms last night for €9,840. Calculate ADR, occupancy and RevPAR."
        let solution = "ADR = 9,840 ÷ 82 = €120; occupancy = 82%; RevPAR = €98.40."
        var start = Date()
        let right = try await p.checkAnswer(problem: problem, solution: solution, answer: "ADR 120, occupancy 82%, RevPAR 98.4")
        let wrong = try await p.checkAnswer(problem: problem, solution: solution, answer: "RevPAR = 9840 / 82 = 120")
        print("check: \(Int(Date().timeIntervalSince(start))) s · right → \(right.verdict): \(right.feedbackMd)\n wrong → \(wrong.verdict): \(wrong.feedbackMd)")
        XCTAssertNotEqual(wrong.verdict, "correct", "RevPAR divides by rooms available, not rooms sold")
        start = Date()
        let fb = try await p.explainFeedback(topic: "RevPAR", keyIdeas: "RevPAR = ADR × occupancy; it combines price and how full the hotel is; revenue per available room.",
                                             explanation: "RevPAR is how much money the hotel makes from each room it sold.")
        print("explain: \(Int(Date().timeIntervalSince(start))) s · \(fb.feedbackMd) · missing \(fb.missing)")
        XCTAssertFalse(fb.feedbackMd.isEmpty)
        #else
        throw XCTSkip("No FoundationModels")
        #endif
    }

    func testAppleOnDeviceChatsWithTools() async throws {
        #if canImport(FoundationModels)
        try XCTSkipUnless(AppleProviders.availability(Catalog.appleOnDevice).available)
        let store = try makeStore(file: true)
        let ids = try seedCourses(store)
        _ = try store.saveAssignment(Assignment(courseId: ids.hm, title: "Pricing report", kind: .report, dueAt: Date().addingTimeInterval(3 * 86_400), weightPct: 30))
        let provider = try AppleProviders.make(Catalog.appleOnDevice)
        var messages: [ChatMessage] = [.system(Prompts.studyRules), .user("What do I have due this week? Use the tools.")]
        let tools = LockedBox<[String]>([])
        let (reply, _) = try await AgentLoop(provider: provider, model: "system", host: try MCPToolHost(paths: store.paths, allowed: AITask.freeChatTools)).run(&messages) { e in
            if case .toolStarted(let n) = e { tools.value.append(n) }
        }
        print("tools:", tools.value, "reply:", reply.text)
        XCTAssertFalse(tools.value.isEmpty, "the model used a Study Tracker tool")
        XCTAssertTrue(reply.text.localizedCaseInsensitiveContains("pricing"))
        #else
        throw XCTSkip("No FoundationModels")
        #endif
    }
}
