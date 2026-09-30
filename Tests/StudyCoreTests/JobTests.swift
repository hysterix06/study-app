import XCTest
@testable import StudyCore
@testable import StudyMCPCore

final class JobTests: XCTestCase {
    var store: StudyStore!

    override func setUpWithError() throws { store = try makeStore() }

    func testQueueRunsOneAtATimeInOrder() throws {
        let a = try store.enqueueJob(.process, args: ["material_id": "1"], objectKind: "material", objectId: 1, label: "Processing A", mode: .automatic)
        let b = try store.enqueueJob(.process, args: ["material_id": "2"], objectKind: "material", objectId: 2, label: "Processing B", mode: .automatic)
        XCTAssertEqual(store.nextQueuedJob()?.id, a)
        try store.setJobState(a, .running)
        XCTAssertNil(store.nextQueuedJob(), "a second job waits instead of failing")
        XCTAssertEqual(store.job(b)?.state, .queued)
        try store.setJobState(a, .done, summary: "Added 3 concepts")
        XCTAssertEqual(store.nextQueuedJob()?.id, b)
        let done = try XCTUnwrap(store.job(a))
        XCTAssertNotNil(done.startedAt)
        XCTAssertNotNil(done.finishedAt)
        XCTAssertEqual(done.resultSummary, "Added 3 concepts")
    }

    func testCancelAndActiveDuplicates() throws {
        let a = try store.enqueueJob(.examPatterns, args: ["material_id": "4"], objectKind: "material", objectId: 4, label: "Exam", mode: .automatic)
        XCTAssertEqual(store.activeJob(.examPatterns, objectKind: "material", objectId: 4)?.id, a)
        try store.setJobState(a, .canceled)
        XCTAssertNil(store.activeJob(.examPatterns, objectKind: "material", objectId: 4))
        XCTAssertNil(store.nextQueuedJob())
    }

    func testDesktopJobFinishesOnItsFinalWrite() throws {
        let id = try store.enqueueJob(.process, args: [:], objectKind: "material", objectId: 1, label: "Processing", mode: .desktop)
        try store.setJobState(id, .handedOff)
        XCTAssertEqual(store.jobsNeedingAttention().map(\.id), [id])
        XCTAssertFalse(try store.attachJobResult(id, tool: "save_concepts", args: [:], count: 14))
        XCTAssertEqual(store.job(id)?.state, .waiting)
        XCTAssertFalse(try store.attachJobResult(id, tool: "propose_cards", args: [:], count: 22))
        XCTAssertTrue(try store.attachJobResult(id, tool: "mark_material_processed", args: [:], count: 1))
        let job = try XCTUnwrap(store.job(id))
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.resultSummary, "Added 14 concepts · 22 cards to approve")
        XCTAssertTrue(store.jobsNeedingAttention().isEmpty)
    }

    func testFinishingToolsAndLabels() {
        XCTAssertTrue(ClaudeTask.examPatterns.isFinished(by: "save_note", args: ["kind": "exam_patterns"]))
        XCTAssertFalse(ClaudeTask.examPatterns.isFinished(by: "save_note", args: ["kind": "summary"]))
        XCTAssertTrue(ClaudeTask.quiz.isFinished(by: "record_session", args: [:]))
        XCTAssertEqual(Set(ClaudeTask.allCases.map(\.label)).count, ClaudeTask.allCases.count, "one distinct label per task")
        for t in ClaudeTask.allCases { XCTAssertTrue(t.label.hasSuffix("Claude"), t.label) }
    }

    func testInterruptedRunsFail() throws {
        let id = try store.enqueueJob(.process, args: [:], objectKind: nil, objectId: nil, label: "x", mode: .automatic)
        try store.setJobState(id, .running)
        store.failInterruptedJobs()
        XCTAssertEqual(store.job(id)?.state, .failed)
    }

    func testPromptCarriesJobId() throws {
        let text = try Prompts.render("weekly_plan", args: ["job_id": "12"], store: store)
        XCTAssertTrue(text.contains("job_id: 12"))
        XCTAssertFalse(try Prompts.render("weekly_plan", args: [:], store: store).contains("job_id"))
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
        let job = try store.enqueueJob(.process, args: ["material_id": "\(materialId!)"], objectKind: "material", objectId: materialId,
                                       label: "Processing", mode: .desktop)
        try store.setJobState(job, .handedOff)
        var args = concepts(chunkIds(materialId))
        args["job_id"] = job
        XCTAssertFalse(call("save_concepts", args).isError)
        XCTAssertEqual(store.job(job)?.state, .waiting)
        XCTAssertEqual(store.job(job)?.results["save_concepts"], 2)
        XCTAssertFalse(call("mark_material_processed", ["material_id": materialId!, "job_id": job]).isError)
        XCTAssertEqual(store.job(job)?.state, .done)
        XCTAssertEqual(store.job(job)?.resultSummary, "Added 2 concepts")
    }
}
