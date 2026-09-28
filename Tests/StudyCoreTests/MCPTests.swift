import XCTest
@testable import StudyCore
@testable import StudyMCPCore

final class MCPTests: XCTestCase {
    var store: StudyStore!
    var server: MCPServer!
    var ids: (term: Int, hm: Int, mkt: Int)!
    var materialId: Int!
    var otherMaterialId: Int!

    override func setUpWithError() throws {
        store = try makeStore(file: true)
        ids = try seedCourses(store)
        let deck = try FixtureFactory.pptx(slides: [
            (title: "Overbooking", bullets: [(0, "Why hotels overbook")], notes: nil, picture: nil, table: nil, chart: false),
            (title: "No-shows", bullets: [(0, "Forecast no-show rate")], notes: nil, picture: "No-show rate chart", table: nil, chart: false),
            (title: "Walking guests", bullets: [(0, "Service recovery")], notes: nil, picture: nil, table: nil, chart: false),
        ])
        guard case .imported(let m, _) = store.importMaterial(from: deck, courseId: ids.hm) else { return XCTFail() }
        materialId = m
        guard case .imported(let o, _) = store.importMaterial(from: FixtureFactory.textPDF(pages: ["Other material"]), courseId: ids.mkt) else { return XCTFail() }
        otherMaterialId = o
        server = MCPServer(paths: store.paths, readOnly: false)
    }

    func call(_ name: String, _ args: [String: Any] = [:], on s: MCPServer? = nil) -> (isError: Bool, json: Any?, raw: [String: Any]) {
        let resp = (s ?? server).handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])!
        let result = resp["result"] as! [String: Any]
        let content = result["content"] as! [[String: Any]]
        let text = content.first?["text"] as? String
        return (result["isError"] as? Bool ?? false, JSON.parse(text), result)
    }

    func chunkIds(_ m: Int) -> [Int] { store.chunks(materialId: m).map(\.id) }

    func concepts(_ ids: [Int]) -> [String: Any] {
        ["material_id": materialId!, "concepts": [
            ["name": "Overbooking", "definition": "Selling more rooms than exist, expecting no-shows.", "importance": 1, "source_chunk_ids": [ids[0]],
             "links": [["to_name": "No-show rate", "relation": "prerequisite"]]],
            ["name": "No-show rate", "definition": "Share of bookings that do not arrive.", "importance": 2, "source_chunk_ids": [ids[1]]],
        ]]
    }

    func testInitializeAndToolList() {
        let r = server.handle(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]])!
        let result = r["result"] as! [String: Any]
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let tools = ((server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])!["result"] as! [String: Any])["tools"] as! [[String: Any]]).map { $0["name"] as! String }
        XCTAssertTrue(tools.contains("get_overview"))
        XCTAssertTrue(tools.contains("save_concepts"))
        // No tool that deletes or edits protected tables, and no raw SQL.
        for name in tools {
            XCTAssertFalse(name.contains("delete") || name.contains("sql") || name.contains("update_") || name.contains("edit"), name)
        }
        let allowedWrites: Set = ["save_concepts", "save_questions", "propose_cards", "save_cornell_sheet", "save_note", "propose_assignments",
                                  "propose_study_blocks", "mark_material_processed", "record_session", "log_review"]
        let writes = Set(ToolCatalog.writeTools.map(\.name))
        XCTAssertEqual(writes, allowedWrites)
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]), "notifications get no reply")
    }

    func testReadToolsSucceed() {
        for (name, args) in [("get_overview", [:]), ("list_courses", [:]), ("list_assignments", [:]), ("list_materials", [:]),
                             ("get_material", ["material_id": materialId!]), ("get_chunks", ["material_id": materialId!]),
                             ("get_schedule", ["from": "2026-09-28", "to": "2026-10-04"]), ("get_grade_summary", ["course_id": ids.hm]),
                             ("get_concepts", ["course_id": ids.hm]), ("get_questions", ["material_id": materialId!]),
                             ("get_review_queue", [:]), ("get_notes", [:]), ("get_outcomes", [:]),
                             ("get_handwriting_captures", ["material_id": materialId!])] as [(String, [String: Any])] {
            let r = call(name, args)
            XCTAssertFalse(r.isError, "\(name): \(String(describing: r.json))")
        }
    }

    func testGetSlideImagesReturnsImages() {
        let r = call("get_slide_images", ["material_id": materialId!, "ordinals": [2]])
        XCTAssertFalse(r.isError)
        let content = r.raw["content"] as! [[String: Any]]
        XCTAssertTrue(content.contains { $0["type"] as? String == "image" && ($0["mimeType"] as? String) == "image/jpeg" })
    }

    func testValidationFailures() {
        XCTAssertEqual((call("get_material", [:]).json as? [String: Any])?["code"] as? String, "INVALID_ARGUMENT")
        XCTAssertEqual((call("get_material", ["material_id": 9999]).json as? [String: Any])?["code"] as? String, "NOT_FOUND")
        XCTAssertEqual((call("get_schedule", ["from": "2026-01-01", "to": "2026-12-31"]).json as? [String: Any])?["code"] as? String, "INVALID_ARGUMENT")
        let tooMany = (0..<31).map { ["name": "C\($0)", "definition": "d", "importance": 1, "source_chunk_ids": [chunkIds(materialId)[0]]] }
        XCTAssertEqual((call("save_concepts", ["material_id": materialId!, "concepts": tooMany]).json as? [String: Any])?["code"] as? String, "TOO_LARGE")
        XCTAssertEqual((call("log_review", ["card_id": 1, "rating": 7]).json as? [String: Any])?["code"] as? String, "INVALID_ARGUMENT")
    }

    func testSaveConceptsRejectsChunksFromAnotherMaterial() {
        let foreign = chunkIds(otherMaterialId)[0]
        let r = call("save_concepts", ["material_id": materialId!, "concepts": [
            ["name": "X", "definition": "Y", "importance": 1, "source_chunk_ids": [foreign]]]])
        XCTAssertTrue(r.isError)
        let body = r.json as! [String: Any]
        XCTAssertEqual(body["code"] as? String, "INVALID_REFERENCE")
        XCTAssertTrue((body["hint"] as? String ?? "").contains("get_material"))
    }

    func testSaveConceptsLinksAndCourseLevelReuse() {
        let c = chunkIds(materialId)
        let r = call("save_concepts", concepts(c))
        XCTAssertFalse(r.isError, "\(String(describing: r.json))")
        XCTAssertEqual((r.json as! [String: Any])["created"] as? Int, 2)
        XCTAssertEqual(store.conceptLinks(courseId: ids.hm).count, 1)
        // Same name again (different case) updates rather than duplicates, and adds sources.
        let again = call("save_concepts", ["material_id": materialId!, "concepts": [
            ["name": "overbooking", "definition": "Refined definition.", "importance": 1, "source_chunk_ids": [c[2]]]]])
        XCTAssertEqual((again.json as! [String: Any])["updated"] as? Int, 1)
        XCTAssertEqual(store.concepts(courseId: ids.hm).count, 2)
        XCTAssertEqual(store.conceptSources(store.concepts(courseId: ids.hm).first { $0.name == "Overbooking" }!.id).count, 2)
    }

    func testClaudeNeverOverwritesUserRows() throws {
        try store.saveUserConcept(courseId: ids.hm, name: "Overbooking", definition: "My own words.", importance: 1)
        let r = call("save_concepts", concepts(chunkIds(materialId)))
        let skipped = (r.json as! [String: Any])["skipped"] as! [[String: Any]]
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(store.concepts(courseId: ids.hm).first { $0.name == "Overbooking" }?.definition, "My own words.")

        _ = try store.saveUserNote(courseId: ids.hm, materialId: materialId, title: "Gaps", content: "mine")
        // A Claude note with the same title and kind collides only with Claude notes; user notes are a different kind.
        let n = call("save_note", ["material_id": materialId!, "kind": "gap_report", "title": "Gaps", "content_md": "claude"])
        XCTAssertFalse(n.isError)
        XCTAssertEqual(store.notes(materialId: materialId, kind: "user_note").first?.contentMd, "mine")
        XCTAssertTrue(call("save_note", ["material_id": materialId!, "kind": "user_note", "title": "T", "content_md": "x"]).isError)
        // Second save of the same Claude note updates it.
        let n2 = call("save_note", ["material_id": materialId!, "kind": "gap_report", "title": "Gaps", "content_md": "claude v2"])
        XCTAssertEqual((n2.json as! [String: Any])["updated"] as? Int, 1)
    }

    func testProposeAssignmentsInsertsUnconfirmedAndSkipsDuplicates() {
        let item: [String: Any] = ["course_id": ids.hm, "title": "Pricing report", "due_at": "2026-10-23T23:59:00+02:00", "weight_pct": 30]
        let r = call("propose_assignments", ["items": [item, ["course_id": ids.hm, "title": "Final exam"]]])
        XCTAssertFalse(r.isError, "\(String(describing: r.json))")
        XCTAssertEqual((r.json as! [String: Any])["created"] as? Int, 2)
        let proposed = store.assignments(AssignmentFilter(onlyProposed: true))
        XCTAssertEqual(proposed.count, 2)
        XCTAssertTrue(proposed.allSatisfy { !$0.confirmed && $0.source == "claude" })
        XCTAssertTrue(store.assignments().isEmpty, "proposals never appear as confirmed work")
        let dup = call("propose_assignments", ["items": [["course_id": ids.hm, "title": "pricing REPORT", "due_at": "2026-10-23T20:00:00Z"]]])
        XCTAssertEqual((dup.json as! [String: Any])["created"] as? Int, 0)
        let noOffset = call("propose_assignments", ["items": [["course_id": ids.hm, "title": "X", "due_at": "2026-10-23T23:59"]]])
        XCTAssertTrue(noOffset.isError)
    }

    func testMarkProcessedPrecondition() {
        let r = call("mark_material_processed", ["material_id": materialId!])
        XCTAssertEqual((r.json as! [String: Any])["code"] as? String, "PRECONDITION")
        _ = call("save_concepts", concepts(chunkIds(materialId)))
        XCTAssertFalse(call("mark_material_processed", ["material_id": materialId!]).isError)
        XCTAssertNotNil(store.material(materialId)?.processedAt)
    }

    func testQuestionsCardsAndLogReview() throws {
        let c = chunkIds(materialId)
        _ = call("save_concepts", concepts(c))
        let q = call("save_questions", ["material_id": materialId!, "create_cards": true, "questions": [
            ["kind": "recall", "prompt": "What is overbooking?", "answer_key": "Selling more rooms than available.", "concept_name": "Overbooking", "source_chunk_ids": [c[0]]],
            ["kind": "recall", "prompt": "What is overbooking?", "answer_key": "dup", "source_chunk_ids": [c[0]]],
        ]])
        XCTAssertEqual((q.json as! [String: Any])["created"] as? Int, 1)
        XCTAssertEqual(store.cards(status: "proposed").count, 1, "Claude's cards wait for approval")
        let proposed = store.cards(status: "proposed")[0]
        XCTAssertTrue(call("log_review", ["card_id": proposed.id, "rating": 3]).isError, "proposed cards cannot be reviewed")
        try store.saveCard(id: proposed.id, front: proposed.front, back: "More bookings than rooms.", status: "active")
        let before = store.card(proposed.id)!.due
        let r = call("log_review", ["card_id": proposed.id, "rating": 3])
        XCTAssertFalse(r.isError)
        XCTAssertNotEqual(store.card(proposed.id)!.due, before)
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM card_reviews WHERE card_id = ?", [proposed.id]), 1)
    }

    func testCornellSheetValidation() {
        let c = chunkIds(materialId)
        let good = (1...8).map { ["text": "Why does factor \($0) matter?", "kind": "question", "source_chunk_ids": [c[0]]] as [String: Any] }
        let r = call("save_cornell_sheet", ["material_id": materialId!, "title": "Overbooking", "cues": good,
                                            "summary_prompt": "When is overbooking worth it?", "look_yourself_chunk_ids": [c[1]]])
        XCTAssertFalse(r.isError, "\(String(describing: r.json))")
        XCTAssertEqual(store.notes(kind: "cornell_sheet").count, 1)
        let sheet = CornellSheet.decode(store.notes(kind: "cornell_sheet")[0].dataJson)!
        XCTAssertEqual(sheet.lookYourself, ["slide 2"])
        var withAnswer = good
        withAnswer[0] = ["text": "Overbooking: selling more rooms than the hotel actually has", "kind": "term", "source_chunk_ids": [c[0]]]
        XCTAssertTrue(call("save_cornell_sheet", ["material_id": materialId!, "title": "X", "cues": withAnswer, "summary_prompt": "?"]).isError)
        XCTAssertTrue(call("save_cornell_sheet", ["material_id": materialId!, "title": "X", "cues": Array(good.prefix(3)), "summary_prompt": "?"]).isError)
    }

    func testStudyBlocksAndSessions() {
        let b = call("propose_study_blocks", ["blocks": [["course_id": ids.hm, "planned_start": "2020-01-01T10:00:00Z", "planned_minutes": 60]]])
        XCTAssertFalse(b.isError)
        XCTAssertFalse(((b.json as! [String: Any])["warnings"] as? [String] ?? []).isEmpty, "past blocks warn")
        XCTAssertTrue(call("propose_study_blocks", ["blocks": [["planned_start": "2026-10-01T10:00:00Z", "planned_minutes": 500]]]).isError)
        _ = call("save_concepts", concepts(chunkIds(materialId)))
        let s = call("record_session", ["kind": "recall", "material_id": materialId!, "summary": "Solid on overbooking; shaky on no-show math.",
                                         "weak_concept_names": ["No-show rate", "Unknown thing"], "items_total": 2, "items_correct": 1])
        XCTAssertFalse(s.isError)
        XCTAssertEqual((s.json as! [String: Any])["unmatched_concepts"] as? [String], ["Unknown thing"])
        XCTAssertEqual(store.weakConcepts().first?.concept.name, "No-show rate")
    }

    func testAuditLogAndBackupOnFirstWrite() throws {
        _ = call("save_concepts", concepts(chunkIds(materialId)))
        let audit = try store.db.query("SELECT * FROM audit_log WHERE actor = 'mcp'")
        XCTAssertFalse(audit.isEmpty)
        XCTAssertTrue(audit.allSatisfy { ($0.string("detail") ?? "").count <= 500 })
        let backups = try FileManager.default.contentsOfDirectory(atPath: store.paths.backups.path).filter { $0.hasSuffix(".db") }
        XCTAssertEqual(backups.count, 1)
    }

    func testReadOnlyModeRegistersNoWriteTools() {
        let ro = MCPServer(paths: store.paths, readOnly: true)
        let writes = Set(ToolCatalog.writeTools.map(\.name))
        XCTAssertTrue(Set(ro.toolNames).isDisjoint(with: writes))
        XCTAssertTrue(call("save_concepts", concepts(chunkIds(materialId)), on: ro).isError)
    }

    func testSchemaMismatch() throws {
        try store.db.execute("PRAGMA user_version = 99")
        let s = MCPServer(paths: store.paths, readOnly: false)
        for name in ["get_overview", "list_courses", "save_note"] {
            let r = call(name, [:], on: s)
            XCTAssertEqual((r.json as! [String: Any])["code"] as? String, "SCHEMA_MISMATCH", name)
        }
    }

    func testPromptsListAndRender() {
        let list = (server.handle(["jsonrpc": "2.0", "id": 3, "method": "prompts/list"])!["result"] as! [String: Any])["prompts"] as! [[String: Any]]
        XCTAssertEqual(list.count, Prompts.definitions.count)
        let got = server.handle(["jsonrpc": "2.0", "id": 4, "method": "prompts/get", "params": ["name": "process_lecture", "arguments": ["material_id": "\(materialId!)"]]])!
        let msgs = (got["result"] as! [String: Any])["messages"] as! [[String: Any]]
        let text = (msgs[0]["content"] as! [String: Any])["text"] as! String
        XCTAssertTrue(text.hasPrefix(Prompts.studyRules))
        XCTAssertTrue(text.contains("HM210 Week 3") || text.contains("Overbooking"), "the copied prompt names the lecture")
        for d in Prompts.definitions {
            var args: [String: String] = [:]
            for a in d.arguments { args[a.name] = a.name == "scope" ? "material" : "1" }
            XCTAssertNoThrow(try Prompts.render(d.name, args: args, store: store), d.name)
        }
    }

    /// Runs the real binary over stdio: only protocol messages may appear on stdout.
    func testStdoutCarriesOnlyProtocol() throws {
        let bin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/study-mcp")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else { throw XCTSkip("study-mcp not built at \(bin.path)") }
        let p = Process()
        p.executableURL = bin
        p.environment = ["STUDY_DB_PATH": store.paths.database.path, "STUDY_ROOT": store.paths.root.path, "HOME": NSHomeDirectory()]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = errors
        try p.run()
        let msgs = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_overview","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"save_note","arguments":{"course_id":\#(ids.hm),"kind":"summary","title":"t","content_md":"x"}}}"#,
        ]
        input.fileHandleForWriting.write(Data((msgs.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 4, out)
        for l in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(l.utf8)) as! [String: Any]
            XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        }
        XCTAssertTrue(out.contains("next_class"))
        XCTAssertEqual(store.notes(kind: "summary").count, 1, "the binary wrote to the same database")
    }
}
