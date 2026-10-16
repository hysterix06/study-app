import XCTest
@testable import StudyCore

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
}
