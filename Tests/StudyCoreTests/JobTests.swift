import XCTest
@testable import StudyCore
@testable import StudyMCPCore

final class JobTests: XCTestCase {
    var store: StudyStore!

    override func setUpWithError() throws { store = try makeStore() }

    func job(_ task: AITask, _ object: Int = 1, mode: JobMode = .automatic, priority: Int? = nil) throws -> Int {
        try store.enqueueJob(task, args: ["material_id": "\(object)"], objectKind: "material", objectId: object, label: "\(task.label) \(object)",
                             mode: mode, priority: priority)
    }

    func testEachLaneRunsItsMostUrgentJobFirst() throws {
        let practice = try job(.extractPractice, 1)
        let sort = try job(.sortFiles, 2)
        XCTAssertEqual(store.job(sort)?.priority, AITask.sortFiles.defaultPriority)
        XCTAssertEqual(store.job(sort)?.lane, "everyday")
        XCTAssertEqual(store.nextQueuedJob(lane: "everyday")?.id, sort, "sorting new files beats labelling problems")
        XCTAssertNil(store.nextQueuedJob(lane: "builder"), "a long course build never waits behind file work, and vice versa")
        try store.setJobState(sort, .done, summary: "Sorted 3 files.")
        XCTAssertEqual(store.nextQueuedJob(lane: "everyday")?.id, practice)
        XCTAssertNil(store.nextQueuedJob(lane: "everyday", maxPriority: 0), "during a session only urgent work starts")
        let done = try XCTUnwrap(store.job(sort))
        XCTAssertNotNil(done.finishedAt)
        XCTAssertEqual(done.resultSummary, "Sorted 3 files.")
    }

    func testASortBatchMatchesEachOfItsFiles() throws {
        let id = try store.enqueueJob(.sortFiles, args: ["material_ids": "12,34,56", "quiet": "1"], objectKind: "materials", objectId: 12,
                                      label: "Sorting", mode: .automatic)
        XCTAssertTrue(store.sortingInProgress(12))
        XCTAssertTrue(store.sortingInProgress(34), "not just the first file")
        XCTAssertTrue(store.sortingInProgress(56))
        XCTAssertFalse(store.sortingInProgress(1), "the quiet flag isn't a file")
        XCTAssertFalse(store.sortingInProgress(3), "nor part of another id")
        XCTAssertFalse(store.sortTried(34))
        try store.setJobState(id, .done)
        XCTAssertFalse(store.sortingInProgress(34))
        XCTAssertTrue(store.sortTried(34), "a file the AI left out isn't sent again")
    }

    func testAJobBacksOffThenMovesToTheNextEngine() throws {
        let id = try job(.extractDeadlines)
        try store.setJobState(id, .running)
        let now = Date()
        try store.requeueJob(id, notBefore: now.addingTimeInterval(60), error: "Too many requests.")
        var j = try XCTUnwrap(store.job(id))
        XCTAssertEqual(j.state, .queued)
        XCTAssertEqual(j.attempts, 1)
        XCTAssertTrue(j.enginesTried.isEmpty, "a rate limit tries the same engine again later")
        XCTAssertNil(store.nextQueuedJob(lane: "everyday", now: now), "backing off")
        XCTAssertEqual(store.nextQueuedJob(lane: "everyday", now: now.addingTimeInterval(61))?.id, id)
        XCTAssertNotNil(store.nextJobWake(now: now))
        try store.requeueJob(id, failedEngine: "openrouter|x:free", error: "Key removed.")
        j = try XCTUnwrap(store.job(id))
        XCTAssertEqual(j.enginesTried, ["openrouter|x:free"], "a hard failure rules that engine out for this job")
        XCTAssertNil(j.notBefore)
        try store.setJobTask(id, .sortFiles)
        XCTAssertTrue(store.job(id)!.enginesTried.isEmpty, "a fallback task gives every engine a fresh try")
    }

    func testInterruptedRunsResumeAndStaleOnesClose() throws {
        let running = try job(.sortFiles, 1)
        try store.setJobState(running, .running)
        let tooMany = try job(.extractPractice, 2)
        try store.setJobState(tooMany, .running)
        try store.db.execute("UPDATE claude_jobs SET attempts = 5 WHERE id = ?", [tooMany])
        let handedOff = try job(.checkDraft, 3, mode: .desktop)
        try store.setJobState(handedOff, .handedOff)
        try store.db.execute("UPDATE claude_jobs SET created_at = '2026-01-01T00:00:00Z' WHERE id = ?", [handedOff])
        let retired = try job(.process, 4)
        store.requeueInterruptedJobs()
        XCTAssertEqual(store.job(running)?.state, .queued, "a job the app was running when it quit starts again")
        XCTAssertEqual(store.job(running)?.attempts, 1)
        XCTAssertEqual(store.job(tooMany)?.state, .failed)
        XCTAssertEqual(store.job(handedOff)?.state, .canceled, "a hand-off nobody finished in a week is closed")
        XCTAssertEqual(store.job(retired)?.state, .canceled, "older kinds of task no longer run")
    }

    func testCancelAndActiveDuplicates() throws {
        let a = try job(.extractExam, 4)
        XCTAssertEqual(store.activeJob(.extractExam, objectKind: "material", objectId: 4)?.id, a)
        try store.setJobState(a, .canceled)
        XCTAssertNil(store.activeJob(.extractExam, objectKind: "material", objectId: 4))
        XCTAssertNil(store.nextQueuedJob(lane: "everyday"))
    }

    func testTheStudentPausesDelaysAndReordersJobs() throws {
        let sort = try job(.sortFiles, 1)
        let practice = try job(.extractPractice, 2)
        let exam = try job(.extractExam, 3)
        try store.pauseJob(sort)
        XCTAssertTrue(try XCTUnwrap(store.job(sort)).paused)
        XCTAssertEqual(store.nextQueuedJob(lane: "everyday")?.id, exam, "a paused job never starts")
        XCTAssertNil(store.nextJobWake(), "nor wakes the runner")
        XCTAssertEqual(store.queuedJobCount(lane: "everyday"), 2, "and isn't counted as waiting")
        let now = Date()
        try store.delayJob(exam, until: now.addingTimeInterval(3600))
        XCTAssertEqual(store.nextQueuedJob(lane: "everyday", now: now)?.id, practice)
        XCTAssertEqual(store.nextQueuedJob(lane: "everyday", now: now.addingTimeInterval(3601))?.id, exam, "a delayed job starts on time")
        XCTAssertEqual(store.upcomingJobs(now: now).map(\.id), [practice, exam, sort], "ready, then delayed, then paused")
        try store.runJobNext(sort)
        XCTAssertEqual(store.nextQueuedJob(lane: "everyday", now: now, maxPriority: 0)?.id, sort, "run next resumes it at the front, even in a session")
        try store.setJobState(practice, .running)
        try store.pauseJob(practice)
        XCTAssertEqual(store.job(practice)?.state, .queued, "pausing a running job puts it back in the queue")
        try store.resumeJob(practice)
        XCTAssertFalse(try XCTUnwrap(store.job(practice)).paused)
        try store.setJobState(practice, .done)
        try store.pauseJob(practice)
        XCTAssertFalse(try XCTUnwrap(store.job(practice)).paused, "a finished job stays finished")
    }

    func testPausingAllAIAndTheJobLog() throws {
        XCTAssertFalse(store.aiPaused())
        store.aiPausedUntil = .distantFuture
        XCTAssertTrue(store.aiPaused(), "until the student resumes it")
        store.aiPausedUntil = Date().addingTimeInterval(-1)
        XCTAssertFalse(store.aiPaused(), "a timed pause ends by itself")
        let id = try job(.sortFiles)
        store.addJobEvent(id, .request, "Request 1 sent to sonnet.", file: "AI log/job-\(id)/1 prompt.txt")
        store.addJobEvent(id, .reply, "Reply 1 after 12 s.")
        let log = store.jobEvents(id)
        XCTAssertEqual(log.map(\.kind), [.request, .reply], "oldest first")
        XCTAssertEqual(log.first?.file, "AI log/job-\(id)/1 prompt.txt")
        XCTAssertEqual(store.jobEvents(id, limit: 1).map(\.kind), [.reply], "the latest lines")
        try store.db.execute("DELETE FROM claude_jobs WHERE id = ?", [id])
        XCTAssertTrue(store.jobEvents(id).isEmpty, "the log goes with its job")
    }

    func testDesktopJobFinishesOnItsFinalWrite() throws {
        let id = try store.enqueueJob(.checkDraft, args: ["assignment_id": "1"], objectKind: "assignment", objectId: 1, label: "Checking", mode: .desktop)
        try store.setJobState(id, .handedOff)
        XCTAssertEqual(store.jobsNeedingAttention().map(\.id), [id])
        XCTAssertFalse(try store.attachJobResult(id, tool: "save_note", args: ["kind": "summary"], count: 1))
        XCTAssertEqual(store.job(id)?.state, .waiting)
        XCTAssertTrue(try store.attachJobResult(id, tool: "save_note", args: ["kind": "rubric_check"], count: 1))
        let job = try XCTUnwrap(store.job(id))
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.resultSummary, "Saved 2 notes")
        XCTAssertTrue(store.jobsNeedingAttention().isEmpty)
    }

    func testTasksLabelsAndLanes() {
        XCTAssertEqual(Set(AITask.current.map(\.label)).count, AITask.current.count, "one distinct label per task")
        // Labels name the task, not the engine: the same job runs on Apple, a cloud model, Claude Code or a pasted answer.
        for t in AITask.allCases {
            for brand in ["Claude", "ChatGPT", "Gemini", "Apple", "AI"] { XCTAssertFalse(t.label.contains(brand), t.label) }
        }
        let advice: Set<AITask> = [.checkDraft, .checkAnswer, .explainFeedback]
        for t in AITask.current where !advice.contains(t) && !t.isCourseBuilding { XCTAssertEqual(t.engineLane, .bulk, "\(t) is file work: on device first") }
        for t in advice { XCTAssertEqual(t.engineLane, .quality, "\(t): the student reads it, so the best free model") }
        for t in AITask.current where t.isCourseBuilding {
            XCTAssertEqual(t.engineLane, t.builderTier == "full" ? .builder : .quality, "\(t): the course builder, or the best free model for its basic version")
            XCTAssertEqual(t.queueLane, "builder")
        }
        XCTAssertTrue(AITask.process.isRetired)
        XCTAssertEqual(ClaudeTask.legacy.label, "Older task")
        XCTAssertTrue(AITask.sortFiles.isFinished(by: "set_material_use", args: [:]))
        XCTAssertTrue(AITask.checkDraft.isFinished(by: "save_note", args: ["kind": "rubric_check"]))
    }

    func testUnknownTasksLoadAsLegacy() throws {
        try store.db.execute("INSERT INTO claude_jobs(task, label, mode) VALUES('summon_dragons', 'x', 'automatic')")
        XCTAssertEqual(store.jobs().first?.task, .legacy)
    }

    func testPromptCarriesJobId() throws {
        let text = try Prompts.render("extract_deadlines", args: ["material_id": "3", "job_id": "12"], store: store)
        XCTAssertTrue(text.contains("job_id: 12"))
        XCTAssertFalse(try Prompts.render("extract_deadlines", args: ["material_id": "3"], store: store).contains("job_id"))
    }
}

extension MCPTests {
    func testWriteToolsAdvertiseJobId() {
        let tools = (server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])!["result"] as! [String: Any])["tools"] as! [[String: Any]]
        for t in tools {
            let props = (t["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            let isWrite = ToolCatalog.writeTools.contains { $0.name == t["name"] as? String }
            XCTAssertEqual(props["job_id"] != nil, isWrite, t["name"] as? String ?? "")
        }
    }

    func testTaggedWritesCompleteTheJob() throws {
        let job = try store.enqueueJob(.sortFiles, args: ["material_ids": "\(materialId!)"], objectKind: "material", objectId: materialId,
                                       label: "Sorting", mode: .desktop)
        try store.setJobState(job, .handedOff)
        XCTAssertFalse(call("set_material_use", ["material_id": materialId!, "role": "lecture", "confidence": 0.9, "reason": "Slides.", "job_id": job]).isError)
        XCTAssertEqual(store.job(job)?.state, .done)
        XCTAssertEqual(store.job(job)?.results["set_material_use"], 1)
        XCTAssertEqual(store.job(job)?.resultSummary, "Sorted 1 file")
    }
}
