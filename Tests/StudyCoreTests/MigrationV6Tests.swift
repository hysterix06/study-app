import XCTest
@testable import StudyCore

/// v6 rebuilds `materials` and `study_sessions`. A rebuild drops the old table, so with foreign keys on it would delete
/// every chunk, source and question of every file. These tests build a database the way v5 left it and migrate it.
final class MigrationV6Tests: XCTestCase {
    /// A lecture with chunks, a concept and its source, questions, a reviewed card, a handwriting capture, a sheet and a
    /// session, plus a tutorial the student skipped in the old Inbox.
    func v5Database(path: String = ":memory:") throws -> Database {
        let db = try Database(path: path)
        try Migrations.migrate(db, upTo: 5)
        XCTAssertEqual(db.userVersion, 5)
        try db.executeScript("""
        INSERT INTO terms(id, name, start_date, end_date, is_current) VALUES(1, 'Fall 2026', '2026-09-07', '2026-12-18', 1);
        INSERT INTO courses(id, term_id, code, name) VALUES(1, 1, 'HM210', 'Revenue Management');
        INSERT INTO materials(id, course_id, title, kind, role, content_hash, status, processed_at) VALUES
          (1, 1, 'Week 1', 'slides', 'lecture', 'h1', 'ready', '2026-09-10T10:00:00Z'),
          (2, 1, 'Tutorial 1', 'pdf', 'lecture', 'h2', 'ready', NULL);
        INSERT INTO chunks(id, material_id, ordinal, locator, text_md, token_estimate) VALUES
          (10, 1, 1, 'slide 1', 'RevPAR', 2), (11, 1, 2, 'slide 2', 'ADR', 2), (12, 2, 1, 'p. 1', 'Exercise 1', 3);
        INSERT INTO concepts(id, course_id, first_material_id, name, definition, importance)
          VALUES (20, 1, 1, 'RevPAR', 'Revenue per available room', 1);
        INSERT INTO concept_sources(concept_id, material_id, chunk_id) VALUES (20, 1, 10);
        INSERT INTO questions(id, course_id, material_id, concept_id, kind, prompt, answer_key, source_chunk_ids) VALUES
          (30, 1, 1, 20, 'recall', 'What is RevPAR?', 'Revenue per available room', '[10]'),
          (31, 1, 1, 20, 'calculate', 'ADR 100 and 80% occupancy: RevPAR?', '80', '[10,11]');
        INSERT INTO cards(id, course_id, material_id, concept_id, question_id, front, back, due, state, fsrs_json)
          VALUES (40, 1, 1, 20, 30, 'RevPAR?', 'Revenue per available room', '2026-10-01T00:00:00Z', 2, '{"stability":3.2}');
        INSERT INTO card_reviews(card_id, reviewed_at, rating, state_before) VALUES (40, '2026-09-20T10:00:00Z', 3, 0);
        INSERT INTO handwriting_captures(material_id, image_path, ocr_text) VALUES (1, 'Captures/x.jpg', 'my notes');
        INSERT INTO notes(course_id, material_id, kind, title, content_md, created_by)
          VALUES (1, 1, 'cornell_sheet', 'Sheet', 'cues', 'claude');
        INSERT INTO study_sessions(id, course_id, material_id, kind, started_at) VALUES (50, 1, 1, 'recall', '2026-09-11T10:00:00Z');
        INSERT INTO assignments(id, course_id, title, kind, source_material_id) VALUES (60, 1, 'Final exam', 'exam', 1);
        INSERT INTO settings(key, value) VALUES ('inbox_skipped_materials', '[2]');
        """)
        return db
    }

    static let kept = ["materials", "chunks", "concepts", "concept_sources", "questions", "cards", "card_reviews",
                       "handwriting_captures", "notes", "study_sessions", "assignments"]

    func testEveryRowSurvivesAndNoReferenceBreaks() throws {
        let db = try v5Database()
        var before: [String: Int] = [:]
        for t in Self.kept { before[t] = try db.scalarInt("SELECT count(*) FROM \(t)") }

        try Migrations.migrate(db)

        XCTAssertEqual(db.userVersion, Migrations.currentVersion)
        for t in Self.kept { XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM \(t)"), before[t], "\(t) lost rows") }
        XCTAssertTrue(try db.query("PRAGMA foreign_key_check").isEmpty)
        XCTAssertEqual(try db.scalarInt("PRAGMA foreign_keys"), 1, "foreign keys are back on after the migration")
        XCTAssertEqual(try db.scalarInt("SELECT source_material_id FROM assignments WHERE id = 60"), 1, "links to files survive")
    }

    func testCardsKeepTheirReviewHistory() throws {
        let db = try v5Database()
        try Migrations.migrate(db)
        let card = try XCTUnwrap(db.first("SELECT * FROM cards WHERE id = 40"))
        XCTAssertEqual(card.str("fsrs_json"), #"{"stability":3.2}"#)
        XCTAssertEqual(card.int("state"), 2)
        XCTAssertEqual(card.str("due"), "2026-10-01T00:00:00Z")
        XCTAssertNil(card.int("topic_id"))
        XCTAssertEqual(try db.scalarInt("SELECT rating FROM card_reviews WHERE card_id = 40"), 3)
    }

    func testSkippedFilesBecomeNotUsedAndOldFilesAreMarkedLegacy() throws {
        let db = try v5Database()
        try Migrations.migrate(db)
        let tutorial = Material(row: try XCTUnwrap(db.first("SELECT * FROM materials WHERE id = 2")))
        XCTAssertTrue(tutorial.excluded)
        XCTAssertEqual(tutorial.roleSource, "user", "the student set it aside, so sorting never brings it back")
        XCTAssertEqual(tutorial.readState, "skipped")
        XCTAssertEqual(tutorial.group, .notUsed)
        XCTAssertNil(try db.scalarString("SELECT value FROM settings WHERE key = 'inbox_skipped_materials'"))

        let lecture = Material(row: try XCTUnwrap(db.first("SELECT * FROM materials WHERE id = 1")))
        XCTAssertFalse(lecture.excluded)
        XCTAssertEqual(lecture.roleSource, "legacy")
        XCTAssertEqual(lecture.readState, "pending")
        XCTAssertEqual(lecture.group, .path)
        XCTAssertNotNil(lecture.processedAt)
    }

    func testOldQuestionsBecomePractice() throws {
        let db = try v5Database()
        try Migrations.migrate(db)
        let rows = try db.query("SELECT * FROM practice_items ORDER BY legacy_question_id")
        XCTAssertEqual(rows.map { $0.i("legacy_question_id") }, [30, 31])
        XCTAssertEqual(rows.map { $0.str("kind") }, ["short", "calculate"])
        XCTAssertEqual(rows.map { $0.str("source") }, ["generated", "generated"])
        XCTAssertEqual(rows[1].str("chunk_ids_json"), "[10,11]")
        XCTAssertEqual(rows[1].str("solution_md"), "80")
        XCTAssertEqual(rows[0].i("material_id"), 1)
    }

    func testSessionsKeepTheirKindAndGainSteps() throws {
        let db = try v5Database()
        try Migrations.migrate(db)
        let s = StudySession(row: try XCTUnwrap(db.first("SELECT * FROM study_sessions WHERE id = 50")))
        XCTAssertEqual(s.kind, "recall")
        XCTAssertNil(s.topicId)
        XCTAssertNil(s.step)
        try db.execute("INSERT INTO study_sessions(kind, mode, step, started_at) VALUES('notebook', 'standard', 'notebook', '2026-10-07T10:00:00Z')")
    }

    func testDeletesStillCascadeAfterTheRebuild() throws {
        let db = try v5Database()
        try Migrations.migrate(db)
        try db.execute("DELETE FROM materials WHERE id = 1")
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM chunks WHERE material_id = 1"), 0)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM concept_sources"), 0)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM practice_items WHERE material_id = 1"), 0)
        XCTAssertNil(try db.first("SELECT source_material_id FROM assignments WHERE id = 60 AND source_material_id IS NOT NULL"))
    }

    func testNewRolesAndTablesAcceptTheirValues() throws {
        let db = try v5Database()
        try Migrations.migrate(db)
        try db.execute("UPDATE materials SET role = 'practice' WHERE id = 2")
        try db.execute("UPDATE materials SET role = 'example' WHERE id = 2")
        XCTAssertThrowsError(try db.execute("UPDATE materials SET role = 'notes' WHERE id = 2"))
        try db.execute("INSERT INTO course_paths(id, course_id, tier) VALUES(1, 1, 'full')")
        try db.execute("INSERT INTO path_units(id, path_id, ordinal, title) VALUES(1, 1, 1, 'Pricing')")
        try db.execute("INSERT INTO path_topics(id, course_id, unit_id, ordinal, key, title, mastery) VALUES(1, 1, 1, 1, 'revpar', 'RevPAR', 'familiar')")
        XCTAssertThrowsError(try db.execute("INSERT INTO path_topics(course_id, key, title) VALUES(1, 'revpar', 'RevPAR again')"),
                             "one topic per key in a course")
        try db.execute("INSERT INTO topic_checks(topic_id, kind, rating) VALUES(1, 'notebook_review', 'shaky')")
        XCTAssertThrowsError(try db.execute("INSERT INTO topic_checks(topic_id, kind, rating, rated_by) VALUES(1, 'explain', 'mostly', 'ai')"),
                             "ratings are the student's own")
        let job = try db.execute("INSERT INTO claude_jobs(task, label, mode) VALUES('build_path', 'Build HM210', 'automatic')").lastInsertId
        let row = try XCTUnwrap(db.first("SELECT lane, priority, attempts, engines_tried FROM claude_jobs WHERE id = ?", [job]))
        XCTAssertEqual(row.str("lane"), "everyday")
        XCTAssertEqual(row.int("priority"), 50)
        XCTAssertEqual(row.str("engines_tried"), "[]")
    }

    func testOpeningAnOldDatabaseBacksItUpFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("st-mig-\(UUID().uuidString)")
        let paths = AppPaths(database: root.appendingPathComponent("study.db"), root: root.appendingPathComponent("files"))
        do { _ = try v5Database(path: paths.database.path) }
        let store = try StudyStore.open(paths: paths)
        XCTAssertEqual(store.db.userVersion, Migrations.currentVersion)
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.backups.path)
        XCTAssertTrue(backups.contains { $0.hasSuffix("before-v\(Migrations.currentVersion).db") }, "\(backups)")
    }
}
