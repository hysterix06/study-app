import XCTest
@testable import StudyCore

/// Sessions on the sample course: what each kind holds, saving as it goes, and ratings that are the student's own.
final class SessionTests: XCTestCase {
    var store: StudyStore!
    var hm: Int!
    var topics: [PathTopic] = []

    override func setUpWithError() throws {
        store = try makeStore(file: true)
        try SampleData.load(store)
        hm = try XCTUnwrap(store.courses().first { $0.code == "HM210" }).id
        topics = store.topics(courseId: hm)
    }

    func topic(_ title: String) -> PathTopic { topics.first { $0.title == title }! }

    func testATopicSessionWarmsUpLearnsPractisesExplainsAndLocksIn() throws {
        let t = topic("ADR, occupancy and RevPAR")
        let s = try store.beginSession(SessionPick(kind: .topic, courseId: hm, topicId: t.id, minutes: 25, score: 1), mode: .standard)
        let p = try XCTUnwrap(s.progress)
        XCTAssertEqual(p.steps, [.warmup, .learn, .practice, .explain, .lockin], "the sample's cards are due, and Tutorial 4 has RevPAR problems")
        XCTAssertEqual(store.practiceItem(p.problemIds[0])?.source, "course", "the course's own problems first")
        XCTAssertEqual(s.currentStep, .warmup)

        try store.saveSession(s.id, step: .practice, progress: p)
        XCTAssertEqual(store.refreshMastery(topicId: t.id), .learning, "past the lesson: learning")
        try store.recordAttempt(itemId: p.problemIds[0], sessionId: s.id, answer: "€98.40", rating: "got", aiFeedback: "Looks right.", aiVerdict: "correct")
        XCTAssertThrowsError(try store.recordAttempt(itemId: p.problemIds[0], sessionId: s.id, answer: nil, rating: "perfect"))
        try store.recordCheck(topicId: t.id, sessionId: s.id, kind: "explain", rating: "mostly", answer: "RevPAR mixes price and occupancy.")
        XCTAssertEqual(store.topic(t.id)?.mastery, .practiced)

        let kept = try store.keepCards(topicId: t.id, [LessonCard(front: "RevPAR?", back: "ADR × occupancy"), LessonCard(front: "ADR?", back: "Room revenue ÷ rooms sold")])
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(try store.keepCards(topicId: t.id, [LessonCard(front: "revpar?", back: "again")]).count, 0, "kept once")
        try store.finishSession(s.id)
        XCTAssertNotNil(store.topic(t.id)?.lastStudiedAt)
        XCTAssertEqual(store.session(s.id)?.currentStep, .done)
        XCTAssertTrue(store.unfinishedSessions().isEmpty)
    }

    func testALeftSessionContinuesWhereItStopped() throws {
        let t = topic("Overbooking")
        let s = try store.beginSession(SessionPick(kind: .topic, courseId: hm, topicId: t.id, minutes: 10, score: 1), mode: .quick)
        XCTAssertFalse(s.progress!.steps.contains(.explain), "a quick session skips explaining it back")
        try store.saveSession(s.id, step: .learn, progress: s.progress!)
        let open = try XCTUnwrap(store.unfinishedSessions().first)
        XCTAssertEqual(open.pick?.sessionId, s.id)
        let again = try store.beginSession(open.pick!, mode: .standard)
        XCTAssertEqual(again.id, s.id, "Continue opens the same session")
        XCTAssertEqual(again.currentStep, .learn)
    }

    func testNotebookAndExamPrepSessions() throws {
        let unwritten = topics.filter { !$0.inNotebook }.map(\.id)
        let n = try store.beginSession(SessionPick(kind: .notebook, courseId: hm, topicIds: unwritten, minutes: 10, score: 1), mode: .quick)
        XCTAssertEqual(n.progress?.topicIds, Array(unwritten.prefix(2)), "a quick notebook session writes two pages")

        let exam = try XCTUnwrap(store.assignments(AssignmentFilter(courseId: hm)).first { $0.title == "Final exam" })
        let ids = store.assessmentTopicIds(assignmentId: exam.id)
        let e = try store.beginSession(SessionPick(kind: .examPrep, courseId: hm, assignmentId: exam.id, topicIds: ids, minutes: 25, score: 1), mode: .standard)
        XCTAssertEqual(e.progress?.steps.first, .recall)
        try store.recordCheck(topicId: ids[0], sessionId: e.id, kind: "notebook_review", rating: "shaky")
        try store.recordCheck(topicId: ids[1], sessionId: e.id, kind: "notebook_review", rating: "solid")
        XCTAssertThrowsError(try store.recordCheck(topicId: ids[1], sessionId: e.id, kind: "notebook_review", rating: "nailed"))
        XCTAssertEqual(store.shakyTopics(courseId: hm), [ids[0]])
        XCTAssertEqual(store.reviewedInExamPrep(assignmentId: exam.id), [ids[1]])
        let next = store.practiceFor(topicIds: ids, count: 5, examFirst: true, shakyFirst: true)
        if let first = next.first, next.contains(where: { $0.topicId == ids[0] }) {
            XCTAssertEqual(first.topicId, ids[0], "shaky topics' problems first")
        }
    }
}

/// The bundled lesson renderer: everything it needs is in the repository, and nothing can load from the network.
final class LessonKitTests: XCTestCase {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/LessonKit")

    func testFilesAndPolicy() throws {
        for f in ["lesson.html", "lesson.css", "lesson.js", "LICENSES.txt", "vendor/katex.min.js", "vendor/katex.min.css", "vendor/marked.umd.js",
                  "vendor/fonts/KaTeX_Main-Regular.woff2", "vendor/fonts/KaTeX_Math-Italic.woff2"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path), f)
        }
        let html = try String(contentsOf: dir.appendingPathComponent("lesson.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("default-src 'none'") && html.contains("script-src lessonkit:"), "only the bundle's own scripts")
        XCTAssertFalse(html.contains("http://") || html.contains("https://") || html.contains("//cdn"), "no network")
        let js = try String(contentsOf: dir.appendingPathComponent("lesson.js"), encoding: .utf8)
        XCTAssertTrue(js.contains("trust: false"), "KaTeX can't run commands that load or link")
        XCTAssertTrue(js.contains("html(token) { return esc("), "raw HTML in Markdown is shown as text")
        let licenses = try String(contentsOf: dir.appendingPathComponent("LICENSES.txt"), encoding: .utf8)
        XCTAssertTrue(licenses.contains("KaTeX") && licenses.contains("marked") && licenses.contains("MIT"))
    }
}

final class CourseExportTests: XCTestCase {
    func testThePathNotebookAndLessonsLeaveAsMarkdown() throws {
        let store = try makeStore(file: true)
        try SampleData.load(store)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-export-\(UUID().uuidString)")
        try Exporter.markdownExport(store: store, to: dir, obsidian: false)
        let course = dir.appendingPathComponent("HM210")
        let guide = try String(contentsOf: course.appendingPathComponent("Notebook guide.md"), encoding: .utf8)
        XCTAssertTrue(guide.contains("## Unit 1: Demand and pricing") && guide.contains("$$RevPAR = ADR \\times Occ$$"))
        XCTAssertTrue(guide.contains("Your course: “no-show reservations ÷ total reservations for the date”"))
        XCTAssertTrue(guide.contains("![Demand curve](Notebook%20drawings/"), "the drawing is saved beside the guide")
        let drawings = try FileManager.default.contentsOfDirectory(atPath: course.appendingPathComponent("Notebook drawings").path)
        XCTAssertEqual(drawings.count, 1)
        let path = try String(contentsOf: course.appendingPathComponent("Path.md"), encoding: .utf8)
        XCTAssertTrue(path.contains("1.2 ADR, occupancy and RevPAR · In your notebook · notebook p. 3"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: course.appendingPathComponent("Lessons").path).count, 3)
        let full = try Exporter.fullExport(store: store, to: dir.appendingPathComponent("full"))
        let json = try String(contentsOf: full.appendingPathComponent("study-tracker.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"topic_notebook\"") && json.contains("\"practice_attempts\""))
    }
}
