import XCTest
@testable import StudyCore

final class GradeTests: XCTestCase {
    func a(_ id: Int, _ w: Double?, _ score: Double? = nil, _ max: Double? = nil, minPass: Double? = nil) -> Assignment {
        Assignment(id: id, courseId: 1, title: "A\(id)", status: score != nil ? .graded : .notStarted, weightPct: w, score: score,
                   maxScore: max, minPassPct: minPass)
    }

    func testNoGradedItems() throws {
        let s = try GradeMath.summarize(assignments: [a(1, 50), a(2, 50)], target: 70)
        XCTAssertEqual(s.state, .noData)
        XCTAssertNil(s.currentAverage)
        XCTAssertEqual(s.requiredAverage, 70)
    }

    func testOnTrackAndRequired() throws {
        let s = try GradeMath.summarize(assignments: [a(1, 30, 24, 30), a(2, 20, 15, 20), a(3, 50)], target: 70)
        XCTAssertEqual(s.earned, 39, accuracy: 0.001)       // 24 + 15
        XCTAssertEqual(s.gradedWeight, 50)
        XCTAssertEqual(s.currentAverage!, 78, accuracy: 0.001)
        XCTAssertEqual(s.remainingWeight, 50)
        XCTAssertEqual(s.requiredAverage!, 62, accuracy: 0.001) // (70 − 39) / 50
        XCTAssertEqual(s.state, .onTrack)
        XCTAssertEqual(s.pointsByAssignment[1]!, 24, accuracy: 0.001)
        XCTAssertEqual(s.pointsByAssignment[3]!, 50, accuracy: 0.001)
    }

    func testSecuredAndUnreachable() throws {
        XCTAssertEqual(try GradeMath.summarize(assignments: [a(1, 80, 80, 80), a(2, 20)], target: 70).state, .secured)
        XCTAssertEqual(try GradeMath.summarize(assignments: [a(1, 80, 20, 80), a(2, 20)], target: 70).state, .unreachable)
    }

    func testWeightsNotSummingTo100() throws {
        let s = try GradeMath.summarize(assignments: [a(1, 30, 30, 30), a(2, 40)], target: 60)
        XCTAssertNotNil(s.weightWarning)
        XCTAssertEqual(s.totalWeight, 70)
    }

    func testZeroRemainingWeight() throws {
        let s = try GradeMath.summarize(assignments: [a(1, 100, 50, 100)], target: 70)
        XCTAssertEqual(s.state, .unreachable)
        XCTAssertEqual(s.remainingWeight, 0)
    }

    func testZeroMaxScoreRejected() {
        XCTAssertThrowsError(try GradeMath.summarize(assignments: [a(1, 50, 10, 0)], target: 70)) { e in
            XCTAssertEqual(e as? GradeError, .zeroMaxScore(assignmentId: 1))
        }
    }

    func testScalesAndComponentMinimums() throws {
        // Target 7 on a 0–10 scale = 70%.
        let s = try GradeMath.summarize(assignments: [a(1, 50, 40, 50), a(2, 50, minPass: 40)], target: 7, scale: .ten)
        XCTAssertEqual(s.targetPercent, 70)
        XCTAssertEqual(s.currentOnScale!, 8, accuracy: 0.001)
        XCTAssertEqual(s.pendingMinimums.map(\.id), [2])
        let failed = try GradeMath.summarize(assignments: [a(1, 50, 40, 50), a(2, 50, 15, 50, minPass: 40)], target: 5, scale: .ten)
        XCTAssertEqual(failed.state, .componentFailed)
        XCTAssertEqual(GradeScale.swiss.fromPercent(100), 6)
        XCTAssertEqual(GradeScale.swiss.toPercent(4), 60, accuracy: 0.001)
        XCTAssertEqual(GradeScale.twenty.fromPercent(50), 10)
    }
}

final class FSRSTests: XCTestCase {
    let t0 = ISO.parse("2026-10-01T09:00:00Z")!
    let f = FSRS()

    func testNewCardGood() {
        let r = f.review(FSRSCard(), rating: .good, now: t0)
        XCTAssertEqual(r.card.state, .learning)
        XCTAssertEqual(r.interval, 600, accuracy: 1)
        XCTAssertEqual(r.card.stability, 3.173, accuracy: 0.0001)
        XCTAssertEqual(r.card.reps, 1)
    }

    func testNewCardEasyGraduates() {
        let r = f.review(FSRSCard(), rating: .easy, now: t0)
        XCTAssertEqual(r.card.state, .review)
        XCTAssertEqual(r.card.scheduledDays, 16)
    }

    func testLearningGoodGraduatesAndOrderingHolds() {
        let learning = f.review(FSRSCard(), rating: .good, now: t0).card
        let p = f.preview(learning, now: t0.adding(minutes: 10))
        XCTAssertEqual(p[.good]!.card.state, .review)
        XCTAssertGreaterThanOrEqual(p[.good]!.card.scheduledDays, 1)
        XCTAssertGreaterThan(p[.easy]!.card.scheduledDays, p[.good]!.card.scheduledDays)
        XCTAssertEqual(p[.again]!.card.state, .learning)
    }

    func testReviewIntervalsGrowAndAgainLapses() {
        var c = f.review(FSRSCard(), rating: .good, now: t0).card
        var now = t0.adding(minutes: 10)
        let g1 = f.review(c, rating: .good, now: now)
        c = g1.card
        now = g1.due
        let p = f.preview(c, now: now)
        XCTAssertLessThanOrEqual(p[.hard]!.card.scheduledDays, p[.good]!.card.scheduledDays)
        XCTAssertLessThan(p[.good]!.card.scheduledDays, p[.easy]!.card.scheduledDays)
        XCTAssertGreaterThan(p[.good]!.card.scheduledDays, g1.card.scheduledDays, "intervals grow after a successful review")
        let lapse = p[.again]!
        XCTAssertEqual(lapse.card.state, .relearning)
        XCTAssertEqual(lapse.card.lapses, 1)
        XCTAssertLessThanOrEqual(lapse.card.stability, c.stability)
        XCTAssertEqual(lapse.interval, 600, accuracy: 1)
    }

    func testSerializationRoundTrip() {
        let c = f.review(FSRSCard(), rating: .easy, now: t0).card
        XCTAssertEqual(FSRSCard.decode(c.encode()), c)
    }

    func testStoreLogReviewWritesHistory() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let id = try store.addUserCard(courseId: ids.hm, materialId: nil, front: "RevPAR?", back: "ADR × occupancy")
        let r = try store.logReview(cardId: id, rating: .good, now: t0)
        XCTAssertEqual(store.card(id)?.due, r.due)
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM card_reviews WHERE card_id = ?", [id]), 1)
        XCTAssertEqual(try store.db.scalarString("SELECT rated_by FROM card_reviews"), "user")
    }
}

final class TodayTests: XCTestCase {
    let now = at("2026-09-28", "12:00")

    func inputs(_ assignments: [Assignment], cards: Int = 0, blocks: Set<Int> = [], ready: [Material] = [], recall: [Material] = [],
                proposedCards: Int = 0, free: Double = 30) -> TodayInputs {
        TodayInputs(now: now, assignments: assignments, plannedBlockAssignmentIds: blocks, cardsDue: cards, proposedCards: proposedCards,
                    readyUnprocessed: ready, processedWithoutRecall: recall, nextClassTitle: "Revenue Management", freeHoursUntil: { _ in free })
    }

    func asg(_ id: Int, _ title: String, due: Date?, kind: AssignmentKind = .assignment, status: AssignmentStatus = .notStarted,
             weight: Double? = nil, hours: Double? = nil) -> Assignment {
        Assignment(id: id, courseId: 1, title: title, kind: kind, dueAt: due, status: status, weightPct: weight, estHours: hours)
    }

    func testOverdueWinsAndHeaviestFirst() {
        let s = TodayRules.suggest(inputs([
            asg(1, "Small overdue", due: now.adding(days: -1), weight: 5),
            asg(2, "Big overdue", due: now.adding(days: -2), weight: 40),
            asg(3, "Due tomorrow", due: now.adding(hours: 20)),
        ], cards: 50))
        XCTAssertEqual(s.kind, .finishOverdue)
        XCTAssertEqual(s.assignmentId, 2)
    }

    func testImpactBeatsDueDate() {
        // A 2% quiz due in 40 hours vs a 40% report due in 5 days that needs most of the free time.
        let s = TodayRules.suggest(inputs([
            asg(1, "Tiny quiz", due: now.adding(hours: 40), kind: .quiz, status: .inProgress, weight: 2, hours: 0.5),
            asg(2, "Big report", due: now.adding(days: 5), kind: .report, weight: 40, hours: 12),
        ], free: 14))
        XCTAssertEqual(s.assignmentId, 2)
        XCTAssertEqual(s.kind, .startAtRisk)
    }

    func testDueWithin48hNotStarted() {
        let s = TodayRules.suggest(inputs([asg(1, "Memo", due: now.adding(hours: 30), weight: 10, hours: 1)], free: 20))
        XCTAssertEqual(s.title, "Start: Memo")
    }

    func testExamPlanningThenReviewsThenRecallThenProcess() throws {
        let exam = asg(9, "Final exam", due: now.adding(days: 10), kind: .exam, weight: 50)
        XCTAssertEqual(TodayRules.suggest(inputs([exam], cards: 12)).kind, .planExam)
        XCTAssertEqual(TodayRules.suggest(inputs([exam], cards: 12, blocks: [9])).kind, .review)
        let store = try makeStore()
        let ids = try seedCourses(store)
        let file = FixtureFactory.textPDF(pages: ["Forecasting demand for hotel rooms."])
        guard case .imported(let mid, _) = store.importMaterial(from: file, courseId: ids.hm) else { return XCTFail() }
        let m = store.material(mid)!
        XCTAssertEqual(TodayRules.suggest(inputs([], cards: 3, ready: [m], recall: [m])).kind, .recall)
        XCTAssertEqual(TodayRules.suggest(inputs([], cards: 3, ready: [m])).kind, .process)
        XCTAssertEqual(TodayRules.suggest(inputs([], cards: 3, proposedCards: 4)).kind, .approveCards)
        XCTAssertEqual(TodayRules.suggest(inputs([], cards: 3)).title, "Nothing urgent. Next class: Revenue Management.")
    }

    func testReviewEstimate() {
        let s = TodayRules.suggest(inputs([], cards: 30))
        XCTAssertEqual(s.title, "Review 30 cards (about 10 min)")
    }
}
