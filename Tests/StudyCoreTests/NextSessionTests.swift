import XCTest
@testable import StudyCore

final class NextSessionTests: XCTestCase {
    let now = ISO.parse("2026-10-07T10:00:00Z")!
    let tz = TimeZone(identifier: "Europe/Madrid")!
    var today: LocalDate { LocalDate(now, tz: tz) }
    func inDays(_ n: Double) -> Date { now.addingTimeInterval(n * 86_400) }

    func topic(_ id: Int, course: Int = 1, unit: Int = 1, _ title: String, mastery: Mastery = .new, written: Bool = true,
               prereqs: [Int] = [], emphasis: Int = 1, taught: LocalDate? = nil, skipped: Bool = false) -> NextSessionInput.Topic {
        NextSessionInput.Topic(id: id, courseId: course, unitId: unit, unitOrdinal: unit, ordinal: id, title: title, mastery: mastery, prereqIds: prereqs,
                               emphasis: emphasis, skipped: skipped, notebookWritten: written, taughtOn: taught)
    }

    func plan(_ topics: [NextSessionInput.Topic], exams: [NextSessionInput.Assessment] = [], due: Int = 0, unfinished: [SessionPick] = [],
              mode: SessionMode = .standard) -> NextSessionPlan {
        NextSession.plan(NextSessionInput(now: now, tz: tz, topics: topics, assessments: exams, dueCards: due, unfinished: unfinished, dailyMinutes: 120, mode: mode))
    }

    func testTheNotebookComesFirst() {
        let p = plan([topic(1, "Demand", written: false), topic(2, "Pricing", written: false), topic(3, unit: 2, "Overbooking", written: false)])
        XCTAssertEqual(p.primary?.kind, .notebook)
        XCTAssertEqual(p.primary?.topicIds, [1, 2], "the first unit's pages, in order")
        XCTAssertTrue(p.primary?.reasons.contains(.notebookFirst) ?? false)
        XCTAssertEqual(plan([topic(1, "A", written: false), topic(2, "B", written: false), topic(3, "C", written: false)], mode: .quick).primary?.topicIds,
                       [1, 2], "a quick session writes two pages")
    }

    func testOnceWrittenThePathLeads() {
        let p = plan([topic(1, "Demand", mastery: .familiar), topic(2, "Pricing", mastery: .familiar, prereqs: [1])])
        XCTAssertEqual(p.primary?.kind, .topic)
        XCTAssertEqual(p.primary?.topicId, 1)
        XCTAssertEqual(p.primary?.reasons, [.nextInPath])
    }

    func testAnExamPullsItsTopicsForward() {
        let exam = NextSessionInput.Assessment(id: 9, courseId: 1, title: "Midterm", due: inDays(9), weightPct: 40, topicIds: [3])
        let p = plan([topic(1, "Demand", mastery: .familiar), topic(2, "Pricing", mastery: .familiar), topic(3, "Overbooking", mastery: .familiar)], exams: [exam])
        XCTAssertEqual(p.primary?.topicId, 3)
        XCTAssertEqual(p.primary?.reasons.first, .examIn(days: 9, title: "Midterm"))
    }

    func testAnExamsUrgencyGoesToWhatItBuildsOn() {
        let exam = NextSessionInput.Assessment(id: 9, courseId: 1, title: "Final", due: inDays(5), weightPct: 60, topicIds: [3])
        let p = plan([topic(1, "Demand", mastery: .familiar), topic(2, "Elasticity", mastery: .familiar), topic(3, "Pricing", mastery: .familiar, prereqs: [2])], exams: [exam])
        XCTAssertEqual(p.primary?.topicId, 2, "learn what the exam topic builds on first")
        XCTAssertTrue(p.primary?.reasons.contains(.prereqFor("Pricing")) ?? false)
    }

    func testLecturesThatMovedPastPullTopicsForwardAndWarn() {
        let p = plan([topic(1, "Demand", mastery: .familiar), topic(2, "Pricing", mastery: .familiar, taught: today.adding(days: -6)),
                      topic(3, "Overbooking", mastery: .familiar, taught: today.adding(days: -3))])
        XCTAssertEqual(p.primary?.topicId, 2)
        XCTAssertEqual(p.primary?.reasons.first, .taught(today.adding(days: -6)))
        XCTAssertTrue(p.warnings.contains(.behindClass(courseId: 1, count: 2)))
    }

    func testExamPrepInTheLastTwoWeeks() {
        let exam = NextSessionInput.Assessment(id: 9, courseId: 1, title: "Final", due: inDays(6), weightPct: 60, reviewedTopicIds: [1])
        let p = plan([topic(1, "Demand", mastery: .solid), topic(2, "Pricing", mastery: .practiced, emphasis: 3), topic(3, "Overbooking", mastery: .solid)], exams: [exam])
        XCTAssertEqual(p.primary?.kind, .examPrep)
        XCTAssertEqual(p.primary?.assignmentId, 9)
        XCTAssertEqual(p.primary?.topicIds, [2, 3, 1], "pages not yet reviewed first, the stressed one first; reviewed last")
    }

    func testManyDueCardsMeanAReview() {
        let p = plan([topic(1, "Demand", mastery: .solid)], due: 45)
        XCTAssertEqual(p.primary?.kind, .review)
        XCTAssertEqual(p.primary?.reasons, [.cardsDue(45)])
        XCTAssertNil(plan([topic(1, "Demand", mastery: .solid)], due: 5).primary, "nothing to do")
    }

    func testAnUnfinishedSessionComesFirst() {
        let open = SessionPick(kind: .topic, courseId: 1, topicId: 2, minutes: 25, score: 1, sessionId: 77)
        let p = plan([topic(1, "Demand", written: false)], unfinished: [open])
        XCTAssertEqual(p.primary?.sessionId, 77)
        XCTAssertEqual(p.primary?.reasons.first, .unfinished)
        XCTAssertEqual(p.then.first?.kind, .notebook)
    }

    func testAnOpenTopicIsntAlsoSuggestedAfresh() {
        let notebook = SessionPick(kind: .notebook, courseId: 2, minutes: 25, score: 1, sessionId: 76)
        let open = SessionPick(kind: .topic, courseId: 1, topicId: 1, minutes: 25, score: 1, sessionId: 77)
        let p = plan([topic(1, "Demand"), topic(2, "Supply")], unfinished: [notebook, open])
        let all = [p.primary].compactMap { $0 } + p.then
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "no two suggestions share an id")
        XCTAssertEqual(all.filter { $0.kind == .topic && $0.topicId == 1 }.map(\.sessionId), [77], "only Continue for the open topic")
    }

    func testKnownHiddenAndSolidTopicsAreLeftAlone() {
        let p = plan([topic(1, "Demand", mastery: .solid), topic(2, "Pricing", mastery: .familiar, skipped: true), topic(3, "Overbooking", mastery: .familiar)])
        XCTAssertEqual(p.primary?.topicId, 3)
    }

    func testAFadingTopicComesBack() {
        let p = plan([topic(1, "Demand", mastery: .refresh), topic(2, "Pricing", mastery: .solid)])
        XCTAssertEqual(p.primary?.topicId, 1)
        XCTAssertTrue(p.primary?.reasons.contains(.refresh) ?? false)
    }

    func testTooMuchLeftForTheTimeWarns() {
        let topics = (1...20).map { topic($0, "Topic \($0)", written: false) }
        let exam = NextSessionInput.Assessment(id: 9, courseId: 1, title: "Final", due: inDays(3), weightPct: 60)
        let p = plan(topics, exams: [exam])
        guard case .tightForExam(9, "Final", let need, let have)? = p.warnings.first else { return XCTFail("\(p.warnings)") }
        XCTAssertGreaterThan(need, have)
    }

    func testTheThenRowMixesCourses() {
        let p = plan([topic(1, course: 1, "A", mastery: .familiar), topic(2, course: 1, "B", mastery: .familiar),
                      topic(3, course: 2, "X", mastery: .familiar)])
        XCTAssertEqual(p.primary?.courseId, 1)
        XCTAssertTrue(p.then.contains { $0.courseId == 2 }, "another course shows up when it's nearly as urgent")
    }

    func testSamePlanEveryTime() {
        let topics = [topic(1, "A", mastery: .familiar), topic(2, "B", mastery: .familiar), topic(3, course: 2, "C", mastery: .familiar)]
        XCTAssertEqual(plan(topics), plan(topics))
    }
}
