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

    func testTimetableExpandsAWeekWithExclusionsAndMoves() throws {
        let events = try ICS.parse(fixtureText("outlook.ics"))
        let hm = Timetable.occurrences(events, from: d("2026-10-12"), to: d("2026-10-25"), tz: madrid).filter { $0.summary == "HM210 Revenue Management" }
        // 13 Oct is excluded, 20 Oct moved to 21 Oct 14:00 in another room.
        XCTAssertEqual(hm.map { LocalDate($0.start, tz: madrid) }, [d("2026-10-15"), d("2026-10-21"), d("2026-10-22")])
        XCTAssertEqual(LocalTime(hm[1].start, tz: madrid), t("14:00"))
        XCTAssertEqual(hm[1].location, "Aula Magna")
        XCTAssertEqual(LocalTime(hm[0].start, tz: madrid), t("09:00"))
        // After the clocks change the class stays at 09:00 local time.
        let nov = Timetable.occurrences(events, from: d("2026-11-03"), to: d("2026-11-03"), tz: madrid).first { $0.summary.contains("HM210") }
        XCTAssertEqual(nov.map { LocalTime($0.start, tz: madrid) }, t("09:00"))
        // A COUNT is counted from the start: 14 weekly classes from 14 Sep end on 14 Dec.
        XCTAssertEqual(Timetable.occurrences(events, from: d("2026-12-14"), to: d("2026-12-20"), tz: madrid).filter { $0.summary.contains("MKT201") }.count, 1)
        XCTAssertEqual(Timetable.occurrences(events, from: d("2026-12-21"), to: d("2026-12-27"), tz: madrid).filter { $0.summary.contains("MKT201") }.count, 0)
    }

    func testLongRunningSeriesStillReachesToday() throws {
        let text = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:daily
        SUMMARY:Morning briefing
        DTSTART;TZID=Europe/Madrid:20220103T080000
        DTEND;TZID=Europe/Madrid:20220103T081500
        RRULE:FREQ=DAILY
        END:VEVENT
        BEGIN:VEVENT
        UID:weekly
        SUMMARY:Spanish 2
        DTSTART;TZID=Europe/Madrid:20200106T100000
        DTEND;TZID=Europe/Madrid:20200106T113000
        RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO
        END:VEVENT
        END:VCALENDAR
        """
        let week = Timetable.occurrences(try ICS.parse(text), from: d("2026-10-12"), to: d("2026-10-25"), tz: madrid)
        XCTAssertEqual(week.filter { $0.summary == "Morning briefing" }.count, 14)
        // Every other Monday since 6 January 2020: 12 and 26 October are off weeks, 19 October is on.
        XCTAssertEqual(week.filter { $0.summary == "Spanish 2" }.map { LocalDate($0.start, tz: madrid) }, [d("2026-10-19")])
    }
}
