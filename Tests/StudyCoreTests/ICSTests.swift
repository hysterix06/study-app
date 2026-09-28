import XCTest
@testable import StudyCore

final class ICSTests: XCTestCase {
    let now = at("2026-09-28", "12:00")

    func testParsesOutlookFeatures() throws {
        let events = try ICS.parse(fixtureText("outlook.ics"))
        XCTAssertEqual(events.count, 6)
        let master = events.first { $0.uid.hasPrefix("0400") && $0.recurrenceId == nil }!
        XCTAssertEqual(master.summary, "HM210 Revenue Management")
        XCTAssertEqual(master.rrule?.byDay, [2, 4])
        XCTAssertEqual(master.exdates.count, 1)
        XCTAssertEqual(ICS.timeZone(for: master.dtstart!.tzid!)?.identifier, "Europe/Paris")
        let guest = events.first { $0.uid == "guest-lecture-1" }!
        XCTAssertEqual(guest.summary, "Guest lecture: hotel revenue team, Q&A", "escaped commas are unescaped")
        XCTAssertNil(events.first { $0.summary == "Reminder" }, "VALARM contents do not leak into events")
    }

    func testMalformedFileIsReported() {
        XCTAssertThrowsError(try ICS.parse("this is not a calendar"))
        // Broken lines inside a calendar are skipped, not fatal.
        let partial = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nSUMMARY:OK\nDTSTART:20261001T100000Z\nGARBAGE LINE\nEND:VEVENT\nEND:VCALENDAR"
        XCTAssertEqual(try ICS.parse(partial).count, 1)
    }

    func testMappingProducesPatternsExceptionsEventsAndProposals() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let plan = try store.planICSImport(text: fixtureText("outlook.ics"), role: "school", sourceId: nil, now: now)

        let hmPatterns = plan.patterns.filter { if case .existing(ids.hm) = $0.course { return true }; return false }
        XCTAssertEqual(hmPatterns.map(\.pattern.weekday).sorted(), [2, 4], "one pattern per BYDAY weekday")
        XCTAssertEqual(hmPatterns.first?.pattern.startTime, t("09:00"))
        XCTAssertEqual(hmPatterns.first?.pattern.validTo, d("2026-12-15"))
        let mkt = plan.patterns.first { if case .existing(ids.mkt) = $0.course { return true }; return false }
        XCTAssertNotNil(mkt, "MKT201 is matched by code")
        XCTAssertEqual(mkt?.pattern.validTo, d("2026-12-14"), "COUNT=14 weekly from 14 Sep ends 14 Dec")

        XCTAssertTrue(plan.exceptions.contains { $0.exception.kind == .cancel && $0.exception.originalDate == d("2026-10-13") })
        let moved = plan.exceptions.first { $0.exception.kind == .modify }
        XCTAssertEqual(moved?.exception.originalDate, d("2026-10-20"))
        XCTAssertEqual(moved?.exception.newDate, d("2026-10-21"))
        XCTAssertEqual(moved?.exception.newStartTime, t("14:00"))
        XCTAssertEqual(moved?.exception.newLocation, "Aula Magna")

        XCTAssertEqual(plan.assignments.count, 1)
        XCTAssertEqual(plan.assignments.first?.assignment.confirmed, false)
        XCTAssertEqual(plan.assignments.first?.course, .existing(ids.hm))
        // Biweekly practical expands into individual events; the guest lecture is a single event.
        XCTAssertEqual(plan.events.filter { $0.event.title == "FB150 Kitchen practical" }.count, 5)
        XCTAssertEqual(plan.events.filter { $0.event.title.hasPrefix("Guest") }.count, 1)
        XCTAssertTrue(plan.summary.contains("new"))
    }

    func testFixtureProducesCorrectCalendar() throws {
        let store = try makeStore()
        try seedCourses(store)
        let plan = try store.planICSImport(text: fixtureText("outlook.ics"), role: "school", sourceId: nil, now: now)
        try store.applyICSImport(plan, sourceId: nil)
        let week = store.occurrences(from: d("2026-10-12"), to: d("2026-10-25"))
        let hm = week.filter { $0.title.contains("HM210") }
        // 13 Oct canceled (EXDATE), 15 Oct normal, 20 Oct moved to 21 Oct 14:00, 22 Oct normal.
        XCTAssertEqual(hm.count, 4)
        XCTAssertEqual(hm.first { $0.originalDate == d("2026-10-13") }?.status, .canceled)
        let moved = hm.first { $0.originalDate == d("2026-10-20") }!
        XCTAssertEqual(moved.status, .modified)
        XCTAssertEqual(LocalDate(moved.start, tz: madrid), d("2026-10-21"))
        XCTAssertEqual(LocalTime(moved.start, tz: madrid), t("14:00"))
        // After DST ends the class stays at 09:00 local.
        let nov = store.occurrences(from: d("2026-11-03"), to: d("2026-11-03")).first { $0.title.contains("HM210") }!
        XCTAssertEqual(LocalTime(nov.start, tz: madrid), t("09:00"))
    }

    func testReimportIsIdempotentAndProtectsUserEdits() throws {
        let store = try makeStore()
        try seedCourses(store)
        let text = fixtureText("outlook.ics")
        try store.applyICSImport(try store.planICSImport(text: text, role: "school", sourceId: nil, now: now), sourceId: nil)
        let counts = (store.patterns().count, store.events().count, store.assignments(AssignmentFilter(includeProposed: true)).count)

        let again = try store.planICSImport(text: text, role: "school", sourceId: nil, now: now)
        XCTAssertEqual(again.newCount, 0)
        XCTAssertEqual(again.changedCount, 0)
        try store.applyICSImport(again, sourceId: nil)
        XCTAssertEqual(counts.0, store.patterns().count)
        XCTAssertEqual(counts.1, store.events().count)
        XCTAssertEqual(counts.2, store.assignments(AssignmentFilter(includeProposed: true)).count)

        // The student edits the guest lecture; the school then changes it too.
        var guest = store.events().first { $0.title.hasPrefix("Guest") }!
        guest.location = "Room 1"; guest.userModified = true
        try store.saveEvent(guest)
        let changed = text.replacingOccurrences(of: "DTSTART:20261104T150000Z", with: "DTSTART:20261104T160000Z")
        let plan = try store.planICSImport(text: changed, role: "school", sourceId: nil, now: now)
        XCTAssertEqual(plan.conflictCount, 1)
        try store.applyICSImport(plan, sourceId: nil)
        XCTAssertEqual(store.events().first { $0.id == guest.id }?.location, "Room 1", "user edit preserved")
        XCTAssertEqual(store.conflicts().count, 1)
        try store.resolveConflict(store.conflicts()[0].id, acceptIncoming: true)
        XCTAssertEqual(store.events().first { $0.id == guest.id }?.start, ISO.parse("2026-11-04T16:00:00Z"))
        XCTAssertTrue(store.conflicts().isEmpty)
    }

    func testUnmatchedRecurringClassCreatesCourse() throws {
        let store = try makeStore()
        _ = try store.saveTerm(Term(name: "Fall", startDate: d("2026-09-07"), endDate: d("2026-12-18"), isCurrent: true))
        let plan = try store.planICSImport(text: fixtureText("outlook.ics"), role: "school", sourceId: nil, now: now)
        XCTAssertEqual(Set(plan.newCourses.compactMap(\.code)), ["HM210", "MKT201"])
        try store.applyICSImport(plan, sourceId: nil)
        XCTAssertEqual(store.courses().map(\.code).compactMap { $0 }.sorted(), ["HM210", "MKT201"])
        XCTAssertEqual(store.courses().first { $0.code == "MKT201" }?.name, "Hospitality Marketing")
        let proposal = store.assignments(AssignmentFilter(onlyProposed: true)).first
        XCTAssertNotNil(proposal)
    }

    func testMoodleDeadlinesBecomeProposals() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        let plan = try store.planICSImport(text: fixtureText("moodle.ics"), role: "school", sourceId: nil, now: now)
        XCTAssertEqual(plan.assignments.count, 2)
        let cs = plan.assignments.first { $0.assignment.title == "Case study 2" }
        XCTAssertNotNil(cs, "\"is due\" is trimmed from the title")
        XCTAssertEqual(cs?.assignment.kind, .case_)
        try store.applyICSImport(plan, sourceId: nil)
        XCTAssertEqual(store.assignments(AssignmentFilter(onlyProposed: true)).count, 2)
        _ = ids
    }

    func testBusyCalendarBecomesBusyEvents() throws {
        let store = try makeStore()
        try seedCourses(store)
        let src = try store.addCalendarSource(name: "Shifts", kind: "file", role: "busy", feedURL: nil)
        let plan = try store.planICSImport(text: fixtureText("busy.ics"), role: "busy", sourceId: src, now: now)
        XCTAssertTrue(plan.patterns.isEmpty)
        XCTAssertTrue(plan.events.allSatisfy { $0.event.kind == "busy" })
        XCTAssertGreaterThan(plan.events.count, 20)
        try store.applyICSImport(plan, sourceId: src)
        let fri = store.occurrences(from: d("2026-10-02"), to: d("2026-10-02")).filter { $0.kind == "busy" }
        XCTAssertEqual(fri.count, 1)
        XCTAssertEqual(LocalTime(fri[0].start, tz: madrid), t("18:00"))
    }
}
