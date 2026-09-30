import XCTest
@testable import StudyCore

final class TrashTests: XCTestCase {
    var store: StudyStore!
    var ids: (term: Int, hm: Int, mkt: Int)!
    var materialId: Int!

    override func setUpWithError() throws {
        store = try makeStore(file: true)
        ids = try seedCourses(store)
        let deck = try FixtureFactory.pptx(slides: [
            (title: "Overbooking", bullets: [(0, "Why hotels overbook")], notes: nil, picture: nil, table: nil, chart: false),
            (title: "No-shows", bullets: [(0, "Forecast no-show rate")], notes: nil, picture: nil, table: nil, chart: false),
        ])
        guard case .imported(let m, _) = store.importMaterial(from: deck, courseId: ids.hm) else { return XCTFail() }
        materialId = m
        // Rows hanging off the course and the material, through CASCADE and SET NULL links.
        let db = store.db
        let concept = try db.execute("INSERT INTO concepts(course_id, first_material_id, name, definition, importance) VALUES(?,?,?,?,2)",
                                     [ids.hm, m, "Overbooking", "Selling more rooms than exist"]).lastInsertId
        let chunk = try db.scalarInt("SELECT id FROM chunks WHERE material_id = ? LIMIT 1", [m])
        try db.execute("INSERT INTO concept_sources(concept_id, material_id, chunk_id) VALUES(?,?,?)", [concept, m, chunk])
        let card = try store.addUserCard(courseId: ids.hm, materialId: m, front: "Overbooking?", back: "Selling more rooms")
        try db.execute("INSERT INTO card_reviews(card_id, rating, reviewed_at) VALUES(?,3,'2026-09-20T10:00:00Z')", [card])
        try db.execute("INSERT INTO study_sessions(course_id, material_id, kind, started_at) VALUES(?,?,'recall','2026-09-20T10:00:00Z')", [ids.hm, m])
        try db.execute("INSERT INTO study_blocks(course_id, planned_start, planned_minutes) VALUES(?,'2026-10-01T08:00:00Z',60)", [ids.hm])
        try store.saveAssignment(Assignment(courseId: ids.hm, title: "Case study", kind: .case_, dueAt: at("2026-10-10", "23:59"), sourceMaterialId: m))
        try store.saveEvent(Event(courseId: ids.hm, title: "Guest lecture", start: at("2026-10-02", "10:00"), end: at("2026-10-02", "11:00")))
    }

    /// Every row of every table except the bookkeeping ones, as sorted text.
    func fingerprint() throws -> [String: [String]] {
        let tables = try store.db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").map { $0.str("name") }
        var out: [String: [String]] = [:]
        for t in tables where !["trash", "audit_log"].contains(t) {
            out[t] = try store.db.query("SELECT * FROM \(t)").map { r in
                r.allValues.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
            }.sorted()
        }
        return out
    }

    func testCourseDeleteRestoresExactly() throws {
        let before = try fingerprint()
        let undo = try store.trashCourse(ids.hm)
        XCTAssertNil(store.course(ids.hm))
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM cards"), 0)
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM materials WHERE course_id IS NULL"), 1, "materials are unlinked, not deleted")
        XCTAssertEqual(store.trashItems().map(\.kind), ["course"])

        try store.undo(undo)
        XCTAssertEqual(try fingerprint(), before)
        XCTAssertTrue(store.trashItems().isEmpty)
    }

    func testMaterialDeleteMovesFilesAndRestoresThem() throws {
        let m = store.material(materialId)!
        let stored = store.paths.absolute(m.storedPath!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        store.skipMaterial(materialId)
        let before = try fingerprint()

        let undo = try store.trashMaterial(materialId)
        XCTAssertNil(store.material(materialId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.root.appendingPathComponent(".Trash").path))
        XCTAssertFalse(store.skippedMaterialIds().contains(materialId))

        try store.undo(undo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertEqual(try fingerprint(), before)
    }

    func testTermTakesItsCoursesAndRestores() throws {
        let before = try fingerprint()
        let undo = try store.trashTerm(ids.term)
        XCTAssertTrue(store.courses(includeArchived: true).isEmpty)
        try store.undo(undo)
        XCTAssertEqual(try fingerprint(), before)
    }

    func testBatchWithUpdatesUndoesTogether() throws {
        let card = try store.addUserCard(courseId: ids.mkt, materialId: nil, front: "Q", back: "A")
        let proposed = try store.saveAssignment(Assignment(courseId: ids.mkt, title: "Quiz", kind: .quiz, dueAt: nil, confirmed: false))
        let before = try fingerprint()
        let tid = try store.trash(kind: "inbox_batch", label: "Cleared the Inbox", batchId: "b1") { rec in
            try rec.delete("materials", ids: [materialId])
            try rec.delete("cards", ids: [card])
            try rec.snapshot("assignments", ids: [proposed])
            try store.dismissProposed(proposed)
        }
        XCTAssertTrue(store.assignment(proposed)!.dismissed)
        try store.undo(.trash([tid], label: "Cleared the Inbox"))
        XCTAssertEqual(try fingerprint(), before)
    }

    func testReimportAfterTrashIsAllowedAndBlocksRestore() throws {
        let m = store.material(materialId)!
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("again-\(UUID().uuidString).pptx")
        try FileManager.default.copyItem(at: store.paths.absolute(m.storedPath!), to: copy)
        let undo = try store.trashMaterial(materialId)
        guard case .imported = store.importMaterial(from: copy, courseId: ids.hm) else { return XCTFail("re-import should work") }
        XCTAssertThrowsError(try store.undo(undo)) { XCTAssertTrue("\($0)".contains("added again")) }
    }

    func testPurgeAfterRetention() throws {
        _ = try store.trashMaterial(materialId)
        XCTAssertEqual(store.purgeTrash(now: Date()), 0)
        XCTAssertEqual(store.purgeTrash(now: Date().addingTimeInterval(31 * 86_400)), 1)
        XCTAssertTrue(store.trashItems().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.paths.root.appendingPathComponent(".Trash").path), [])
    }

    func testImportedAssignmentKeepsTombstone() throws {
        let id = try store.saveAssignment(Assignment(courseId: ids.hm, title: "Moodle task", kind: .other, dueAt: nil, externalUid: "moodle:assign:1"))
        let undo = try store.trashAssignment(id)
        XCTAssertNotNil(undo)
        XCTAssertTrue(store.trashItems().isEmpty, "imported rows are tombstoned, not trashed")
        try store.undo(undo!)
        XCTAssertFalse(store.assignment(id)!.dismissed)
    }
}

extension TrashTests {
    /// A course added after a delete can take the deleted course's id; restoring must not overwrite it.
    func testRestoreAfterIdReuseGetsNewIdAndKeepsChildren() throws {
        let mktCards = try store.addUserCard(courseId: ids.mkt, materialId: nil, front: "4 Ps?", back: "Product, price, place, promotion")
        _ = mktCards
        let undo = try store.trashCourse(ids.mkt)
        let newcomer = try store.saveCourse(Course(termId: ids.term, code: "NEW100", name: "Newcomer", color: "sage"))
        XCTAssertEqual(newcomer, ids.mkt, "SQLite reused the id")
        try store.undo(undo)
        let courses = store.courses()
        XCTAssertEqual(store.course(newcomer)?.name, "Newcomer")
        let restored = try XCTUnwrap(courses.first { $0.code == "MKT201" })
        XCTAssertNotEqual(restored.id, newcomer)
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM cards WHERE course_id = ?", [restored.id]), 1)
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM cards WHERE course_id = ?", [newcomer]), 0)
    }
}
