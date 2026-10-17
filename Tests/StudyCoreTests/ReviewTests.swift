import XCTest
@testable import StudyCore

final class ReviewTests: XCTestCase {
    let t0 = ISO.parse("2026-10-16T10:00:00Z")!

    /// A course with one written chapter holding the given flashcards.
    func makeChapter(_ store: BookStore, cards: [(String, String)]) throws -> (course: Int, chapter: Int) {
        let c = try store.upsertMoodleCourse(moodleId: 1, name: "Econ", code: "ECO", start: nil, end: nil, hidden: false).id
        let plan = BookPlan(isCourse: true, title: "Economics", language: "en",
                            chapters: [BookPlan.Chapter(title: "Perfect competition", summary: "s", syllabusRef: nil, week: nil, files: [])])
        try store.saveBook(courseId: c, plan: plan, model: "sonnet", usage: (1, 1), now: t0)
        let ch = store.chapters(courseId: c)[0].id
        try write(store, chapter: ch, cards: cards)
        return (c, ch)
    }

    func write(_ store: BookStore, chapter: Int, cards: [(String, String)]) throws {
        let deck = cards.map { "Q: \($0.0)\nA: \($0.1)" }.joined(separator: "\n")
        let md = BookWriterTests.chapter("Perfect competition").replacingOccurrences(
            of: "Q: RevPAR\nA: Revenue per available room.\nQ: ADR\nA: Average daily rate.", with: deck)
        let doc = ChapterDoc.parse(md)
        try store.saveChapter(chapter, markdown: md, doc: doc, engine: "claude-code", model: "sonnet", usage: (1, 1), milliseconds: 1, now: t0)
    }

    let three = [("Price taker?", "Must accept the market price."), ("Shutdown rule?", "Produce while P ≥ AVC."), ("Normal profit?", "Zero economic profit.")]

    func testFinishingAChapterPutsItsCardsInReview() throws {
        let store = try BookStore.inMemory()
        let (_, ch) = try makeChapter(store, cards: three)
        XCTAssertEqual(store.dueCount(now: t0), 0, "cards wait until the chapter is read")

        store.markRead(ch, now: t0)
        let due = store.dueCards(now: t0)
        XCTAssertEqual(due.map(\.front), ["Price taker?", "Shutdown rule?", "Normal profit?"], "in the chapter's order")
        XCTAssertEqual(due.first?.chapterPosition, 1)
        XCTAssertEqual(due.first?.chapterTitle, "Perfect competition")
        XCTAssertEqual(due.first?.fsrs.state, .new)
        XCTAssertEqual(store.dueCount(now: t0), 3)
    }

    func testASittingBringsAForgottenCardBackUntilItsGot() throws {
        let store = try BookStore.inMemory()
        let (_, ch) = try makeChapter(store, cards: three)
        store.markRead(ch, now: t0)

        var session = ReviewSession(cards: store.dueCards(now: t0))
        session.answer(gotIt: true, store: store, now: t0, duration: 4)
        session.answer(gotIt: false, store: store, now: t0.adding(minutes: 1))
        session.answer(gotIt: true, store: store, now: t0.adding(minutes: 2))
        XCTAssertEqual(session.queue.map(\.front), ["Shutdown rule?"], "the forgotten card comes back at the end")
        session.answer(gotIt: true, store: store, now: t0.adding(minutes: 3))
        XCTAssertTrue(session.isDone)
        XCTAssertEqual(session.answered, 4)

        let ratings = try store.db.query("SELECT rating, duration_ms FROM reviews ORDER BY id").map { $0.i("rating") }
        XCTAssertEqual(ratings, [3, 1, 3, 3], "Got it is Good and Forgot is Again")
        XCTAssertEqual(try store.db.scalarInt("SELECT duration_ms FROM reviews ORDER BY id LIMIT 1"), 4000)

        // Got it first time: three days out. Forgot then got: tomorrow.
        XCTAssertEqual(store.dueCount(now: t0.adding(minutes: 5)), 0)
        let byFront = Dictionary(uniqueKeysWithValues: try store.db.query("SELECT front, due_at FROM cards").map { ($0.str("front"), ISO.parse($0.str("due_at"))!) })
        XCTAssertEqual(byFront["Price taker?"]!.timeIntervalSince(t0) / 86_400, 3, accuracy: 0.01)
        XCTAssertEqual(byFront["Shutdown rule?"]!.timeIntervalSince(t0.adding(minutes: 3)) / 86_400, 1, accuracy: 0.01)
        XCTAssertEqual(store.nextDue(after: t0.adding(minutes: 5)), byFront["Shutdown rule?"])
        XCTAssertEqual(store.dueCount(now: t0.adding(days: 3.1)), 3)
    }

    func testIntervalsGrowWithEachGotIt() throws {
        let store = try BookStore.inMemory()
        let (_, ch) = try makeChapter(store, cards: [three[0]])
        store.markRead(ch, now: t0)
        var now = t0, last: TimeInterval = 0
        for _ in 0..<4 {
            let card = store.dueCards(now: now)[0]
            let next = store.review(card.id, gotIt: true, now: now)!.dueAt!
            XCTAssertGreaterThan(next.timeIntervalSince(now), last)
            last = next.timeIntervalSince(now)
            now = next
        }
        XCTAssertGreaterThan(last / 86_400, 20, "four Got its reach weeks")
    }

    func testHiddenCoursesCardsWait() throws {
        let store = try BookStore.inMemory()
        let (course, ch) = try makeChapter(store, cards: three)
        store.markRead(ch, now: t0)
        store.setHidden(course, true)
        XCTAssertEqual(store.dueCount(now: t0), 0)
        XCTAssertTrue(store.dueCards(now: t0).isEmpty)
        XCTAssertNil(store.nextDue(after: t0.adding(minutes: -1)))
    }

    func testRewritingAReadChapterKeepsReviewedCards() throws {
        let store = try BookStore.inMemory()
        let (_, ch) = try makeChapter(store, cards: three)
        store.markRead(ch, now: t0)
        let reviewed = store.dueCards(now: t0)[0]
        store.review(reviewed.id, gotIt: true, now: t0)

        try write(store, chapter: ch, cards: [("Allocative efficiency?", "P = MC."), ("Price taker?", "Must accept the market price.")])
        let rows = try store.db.query("SELECT id, front, active FROM cards WHERE chapter_id = ? ORDER BY id", [ch])
        XCTAssertEqual(rows.map { $0.str("front") }, ["Price taker?", "Allocative efficiency?"], "the reviewed card stays, unreviewed ones are replaced")
        XCTAssertEqual(rows[0].i("id"), reviewed.id)
        XCTAssertEqual(rows.map { $0.i("active") }, [1, 1], "the chapter was read, so new cards join review at once")
        XCTAssertEqual(store.dueCards(now: t0).map(\.front), ["Allocative efficiency?"], "the reviewed card keeps its schedule")
    }

    func testSchedulingWithoutLearningSteps() {
        let quick = FSRS(learningSteps: false).review(FSRSCard(), rating: .good, now: t0)
        XCTAssertEqual(quick.card.state, .review)
        XCTAssertEqual(quick.card.scheduledDays, 3)
        let forgot = FSRS(learningSteps: false).review(FSRSCard(), rating: .again, now: t0)
        XCTAssertEqual(forgot.card.state, .learning)
        XCTAssertEqual(forgot.interval, 60, accuracy: 1)
    }

    func testCardTextAndTheEndNote() {
        XCTAssertEqual(Card.plain(#"Profit is \( (P - ATC) \times q \)"#), #"Profit is (P - ATC) \times q"#)
        XCTAssertEqual(Card.plain("P ≥ AVC"), "P ≥ AVC")
        let doc = ChapterDoc.parse(BookWriterTests.chapter("One"))
        XCTAssertEqual(doc.payload(kicker: nil, number: 1, language: "en")["cards"] as? Int, 2, "the page says how many cards joined review")
    }
}

final class BackupTests: XCTestCase {
    func testOneCopyADayKeepingSeven() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BookStore.open(paths: AppPaths(database: root.appendingPathComponent("book.db"), root: root))
        store.setSetting("moodle_url", "https://moodle.example.edu")
        let start = ISO.parse("2026-10-01T12:00:00Z")!
        let first = try store.backUpIfDue(now: start)
        XCTAssertNotNil(first)
        XCTAssertNil(try store.backUpIfDue(now: start.addingTimeInterval(3600)), "one a day")
        let copy = try BookStore.open(paths: AppPaths(database: first!, root: root))
        XCTAssertEqual(copy.setting("moodle_url"), "https://moodle.example.edu", "the copy opens and holds the data")
        for day in 1...9 { try store.backUpIfDue(now: start.addingTimeInterval(Double(day) * 86_400)) }
        let all = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path)
        let names = all.filter { $0.hasSuffix(".db") }.sorted()
        XCTAssertFalse(all.contains("book-2026-10-01.db-wal"), "an old copy goes with its side files")
        XCTAssertEqual(names.count, 7)
        XCTAssertEqual(names.last, "book-2026-10-10.db")
    }
}
