import XCTest
@testable import StudyCore

final class ScheduleTests: XCTestCase {
    let courses: [Int: Course] = [1: Course(id: 1, termId: 1, code: "HM210", name: "Revenue Management"),
                                  2: Course(id: 2, termId: 1, code: "MKT201", name: "Hospitality Marketing")]

    func tuesdayPattern(id: Int = 1, course: Int = 1) -> ClassPattern {
        ClassPattern(id: id, courseId: course, weekday: 2, startTime: t("09:00"), endTime: t("10:30"), location: "B204",
                     validFrom: d("2026-09-15"), validTo: d("2026-12-15"), timezone: "Europe/Madrid")
    }

    func expand(_ from: String, _ to: String, patterns: [ClassPattern], exceptions: [ClassException] = [], events: [Event] = [],
                breaks: [TermBreak] = []) -> [Occurrence] {
        ScheduleEngine.expand(from: d(from), to: d(to), patterns: patterns, exceptions: exceptions, events: events, breaks: breaks,
                              courses: courses, displayTimezone: madrid)
    }

    func testWeeklyExpansionAcrossDaylightSavingKeepsLocalTime() {
        // DST ends in Europe on Sunday 25 October 2026.
        let occ = expand("2026-10-19", "2026-11-01", patterns: [tuesdayPattern()])
        XCTAssertEqual(occ.count, 2)
        XCTAssertEqual(occ.map { LocalTime($0.start, tz: madrid) }, [t("09:00"), t("09:00")])
        // Same local time means a one-hour difference in UTC.
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(LocalTime(occ[0].start, tz: utc), t("07:00"))
        XCTAssertEqual(LocalTime(occ[1].start, tz: utc), t("08:00"))
    }

    func testBreaksAreSkipped() {
        let br = TermBreak(id: 1, termId: 1, startDate: d("2026-10-26"), endDate: d("2026-10-30"), label: "Reading week")
        let occ = expand("2026-10-19", "2026-11-08", patterns: [tuesdayPattern()], breaks: [br])
        XCTAssertEqual(occ.map { LocalDate($0.start, tz: madrid) }, [d("2026-10-20"), d("2026-11-03")])
    }

    func testCanceledClassesStayVisible() {
        let ex = ClassException(id: 1, patternId: 1, originalDate: d("2026-10-20"), kind: .cancel)
        let occ = expand("2026-10-19", "2026-10-25", patterns: [tuesdayPattern()], exceptions: [ex])
        XCTAssertEqual(occ.count, 1)
        XCTAssertEqual(occ[0].status, .canceled)
    }

    func testCancelThenModifySameDate() {
        let p = tuesdayPattern()
        let cancel = ClassException(id: 1, patternId: 1, originalDate: d("2026-10-20"), kind: .cancel)
        let occ = expand("2026-10-19", "2026-10-25", patterns: [p], exceptions: [cancel])
        let plan = EditPlanner.plan(occurrence: occ[0], scope: .this, change: ScheduleChange(newStart: t("11:00")),
                                    patterns: [p], exceptions: [cancel], events: [])
        guard case .upsertException(let ex) = plan.mutations.first else { return XCTFail("expected upsert") }
        XCTAssertEqual(ex.kind, .modify)
        XCTAssertEqual(ex.newStartTime, t("11:00"))
        let after = expand("2026-10-19", "2026-10-25", patterns: [p], exceptions: [ex])
        XCTAssertEqual(after[0].status, .modified)
        XCTAssertEqual(LocalTime(after[0].start, tz: madrid), t("11:00"))
    }

    func testMoveClassToDifferentDate() {
        let p = tuesdayPattern()
        let occ = expand("2026-10-19", "2026-10-25", patterns: [p])
        let plan = EditPlanner.plan(occurrence: occ[0], scope: .this, change: ScheduleChange(newDate: d("2026-10-22")),
                                    patterns: [p], exceptions: [], events: [])
        guard case .upsertException(var ex) = plan.mutations.first else { return XCTFail() }
        ex.id = 5
        let after = expand("2026-10-19", "2026-10-25", patterns: [p], exceptions: [ex])
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(LocalDate(after[0].start, tz: madrid), d("2026-10-22"))
        XCTAssertEqual(after[0].key, "p1:2026-10-20", "the key stays tied to the original date")
        // Moved into a week that is outside the original range: still found.
        let moved = expand("2026-10-22", "2026-10-22", patterns: [p], exceptions: [ex])
        XCTAssertEqual(moved.count, 1)
    }

    func testMovingBackToOriginalSlotRemovesException() {
        let p = tuesdayPattern()
        let ex = ClassException(id: 7, patternId: 1, originalDate: d("2026-10-20"), kind: .modify, newStartTime: t("11:00"))
        let occ = expand("2026-10-19", "2026-10-25", patterns: [p], exceptions: [ex])
        let plan = EditPlanner.plan(occurrence: occ[0], scope: .this, change: ScheduleChange(newStart: t("09:00")),
                                    patterns: [p], exceptions: [ex], events: [])
        XCTAssertEqual(plan.mutations, [.deleteException(id: 7)])
    }

    func testFollowingSplitWithoutExceptions() {
        let p = tuesdayPattern()
        let occ = expand("2026-10-27", "2026-10-27", patterns: [p])
        let plan = EditPlanner.plan(occurrence: occ[0], scope: .following, change: ScheduleChange(newStart: t("14:00")),
                                    patterns: [p], exceptions: [], events: [])
        XCTAssertEqual(plan.mutations.count, 2)
        guard case .updatePattern(let old) = plan.mutations[0], case .insertPattern(let new, let reparent) = plan.mutations[1] else { return XCTFail() }
        XCTAssertEqual(old.validTo, d("2026-10-26"))
        XCTAssertEqual(new.validFrom, d("2026-10-27"))
        XCTAssertEqual(new.validTo, d("2026-12-15"))
        XCTAssertEqual(new.startTime, t("14:00"))
        XCTAssertEqual(new.endTime, t("15:30"), "duration is kept")
        XCTAssertTrue(reparent.isEmpty)
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func testFollowingSplitReparentsLaterExceptionsWhenWeekdayUnchanged() {
        let p = tuesdayPattern()
        let early = ClassException(id: 1, patternId: 1, originalDate: d("2026-10-06"), kind: .cancel)
        let late = ClassException(id: 2, patternId: 1, originalDate: d("2026-11-10"), kind: .cancel)
        let occ = expand("2026-10-27", "2026-10-27", patterns: [p], exceptions: [early, late])
        let plan = EditPlanner.plan(occurrence: occ[0], scope: .following, change: ScheduleChange(newLocation: "C001"),
                                    patterns: [p], exceptions: [early, late], events: [])
        guard case .insertPattern(let new, let reparent) = plan.mutations[1] else { return XCTFail() }
        XCTAssertEqual(new.location, "C001")
        XCTAssertEqual(reparent, [2])
    }

    func testWeekdayChangeDropsExceptionsWithWarning() {
        let p = tuesdayPattern()
        let late = ClassException(id: 2, patternId: 1, originalDate: d("2026-11-10"), kind: .cancel)
        let occ = expand("2026-10-27", "2026-10-27", patterns: [p], exceptions: [late])
        // Move to Wednesday.
        let plan = EditPlanner.plan(occurrence: occ[0], scope: .following, change: ScheduleChange(newDate: d("2026-10-28")),
                                    patterns: [p], exceptions: [late], events: [])
        guard case .insertPattern(let new, let reparent) = plan.mutations[1] else { return XCTFail() }
        XCTAssertEqual(new.weekday, 3)
        XCTAssertEqual(new.validFrom, d("2026-10-28"))
        XCTAssertTrue(reparent.isEmpty)
        XCTAssertTrue(plan.mutations.contains(.deleteException(id: 2)))
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("2026-11-10"))

        let all = EditPlanner.plan(occurrence: occ[0], scope: .all, change: ScheduleChange(newDate: d("2026-10-28")),
                                   patterns: [p], exceptions: [late], events: [])
        guard case .updatePattern(let upd) = all.mutations[0] else { return XCTFail() }
        XCTAssertEqual(upd.weekday, 3)
        XCTAssertEqual(all.warnings.count, 1)
    }

    func testOverlappingPatternsForDifferentCourses() {
        let a = tuesdayPattern(id: 1, course: 1)
        var b = tuesdayPattern(id: 2, course: 2)
        b.startTime = t("10:00"); b.endTime = t("11:00")
        let occ = expand("2026-10-20", "2026-10-20", patterns: [a, b])
        XCTAssertEqual(occ.count, 2)
        XCTAssertEqual(Set(occ.compactMap(\.courseId)), [1, 2])
        XCTAssertLessThan(occ[0].start, occ[1].start)
    }

    func testRangeBoundariesAreInclusive() {
        let p = tuesdayPattern()
        XCTAssertEqual(expand("2026-09-15", "2026-09-15", patterns: [p]).count, 1, "valid_from day included")
        XCTAssertEqual(expand("2026-12-15", "2026-12-15", patterns: [p]).count, 1, "valid_to day included")
        XCTAssertEqual(expand("2026-12-16", "2026-12-31", patterns: [p]).count, 0)
        XCTAssertEqual(expand("2026-09-01", "2026-09-14", patterns: [p]).count, 0)
    }

    func testEventsIncludedByStart() {
        let e = Event(id: 40, courseId: nil, title: "Guest lecture", start: at("2026-11-04", "16:00"), end: at("2026-11-04", "17:30"))
        let occ = expand("2026-11-04", "2026-11-04", patterns: [], events: [e])
        XCTAssertEqual(occ.first?.key, "e40")
        XCTAssertEqual(expand("2026-11-05", "2026-11-06", patterns: [], events: [e]).count, 0)
    }

    func testAffectedCountPreview() {
        let p = tuesdayPattern()
        let occ = expand("2026-12-01", "2026-12-01", patterns: [p])[0]
        XCTAssertEqual(EditPlanner.affectedCount(occurrence: occ, scope: .following, patterns: [p], breaks: []), 3)
        XCTAssertEqual(EditPlanner.affectedCount(occurrence: occ, scope: .this, patterns: [p], breaks: []), 1)
        XCTAssertEqual(EditPlanner.affectedCount(occurrence: occ, scope: .all, patterns: [p], breaks: []), 14)
    }

    func testApplyAndUndoRoundTrip() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        var p = tuesdayPattern(); p.id = 0; p.courseId = ids.hm
        let pid = try store.savePattern(p)
        let before = store.occurrences(from: d("2026-09-01"), to: d("2026-12-31")).map { "\($0.key)@\($0.start)" }
        let occ = store.occurrences(from: d("2026-10-27"), to: d("2026-10-27"))[0]
        let plan = EditPlanner.plan(occurrence: occ, scope: .following, change: ScheduleChange(newDate: d("2026-10-29")),
                                    patterns: store.patterns(), exceptions: store.exceptions(), events: [])
        let snap = try store.apply(plan, label: "move")
        XCTAssertEqual(store.patterns().count, 2)
        XCTAssertEqual(store.patterns().first { $0.id == pid }?.validTo, d("2026-10-26"))
        try store.undo(snap)
        XCTAssertEqual(store.patterns().count, 1)
        let after = store.occurrences(from: d("2026-09-01"), to: d("2026-12-31")).map { "\($0.key)@\($0.start)" }
        XCTAssertEqual(before, after)
    }
}
