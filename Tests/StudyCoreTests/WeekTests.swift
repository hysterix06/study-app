import XCTest
@testable import StudyCore

final class WeekTests: XCTestCase {
    /// A Monday and Wednesday class with both kinds of cancellation Outlook produces, and a one-off talk called off.
    let timetable = """
    BEGIN:VCALENDAR
    PRODID:-//Microsoft Corporation//Outlook 16.0 MIMEDIR//EN
    BEGIN:VEVENT
    UID:eco
    SUMMARY:Fundamentals of Economics - Lecture
    DTSTART;TZID=Romance Standard Time:20260907T090000
    DTEND;TZID=Romance Standard Time:20260907T103000
    RRULE:FREQ=WEEKLY;BYDAY=MO,WE
    LOCATION:B204
    END:VEVENT
    BEGIN:VEVENT
    UID:eco
    RECURRENCE-ID;TZID=Romance Standard Time:20261019T090000
    SUMMARY:Fundamentals of Economics - Lecture
    DTSTART;TZID=Romance Standard Time:20261019T090000
    DTEND;TZID=Romance Standard Time:20261019T103000
    STATUS:CANCELLED
    END:VEVENT
    BEGIN:VEVENT
    UID:eco
    RECURRENCE-ID;TZID=Romance Standard Time:20261021T090000
    SUMMARY:Canceled: Fundamentals of Economics - Lecture
    DTSTART;TZID=Romance Standard Time:20261021T090000
    DTEND;TZID=Romance Standard Time:20261021T103000
    END:VEVENT
    BEGIN:VEVENT
    UID:talk
    SUMMARY:Cancelled: Marketing for the Hospitality Industry guest talk
    DTSTART:20261022T150000Z
    DTEND:20261022T160000Z
    END:VEVENT
    BEGIN:VEVENT
    UID:open-day
    SUMMARY:Campus open day
    DTSTART;VALUE=DATE:20261023
    DTEND;VALUE=DATE:20261024
    END:VEVENT
    END:VCALENDAR
    """

    func testCancelledClassesStayInTheWeekMarked() throws {
        let week = Timetable.occurrences(try ICS.parse(timetable), from: d("2026-10-19"), to: d("2026-10-25"), tz: madrid)
        XCTAssertEqual(week.map(\.summary), ["Fundamentals of Economics - Lecture", "Fundamentals of Economics - Lecture", "Marketing for the Hospitality Industry guest talk", "Campus open day"])
        XCTAssertEqual(week.map(\.cancelled), [true, true, true, false], "STATUS:CANCELLED and Outlook's \"Canceled:\" title both count")
        XCTAssertEqual(week[0].location, "B204", "a cancelled class keeps its room")
        let next = Timetable.occurrences(try ICS.parse(timetable), from: d("2026-10-26"), to: d("2026-10-26"), tz: madrid)
        XCTAssertEqual(next.map(\.cancelled), [false], "the series carries on")
    }

    func makeStore() throws -> (BookStore, eco: Int, mkt: Int) {
        let store = try BookStore.inMemory()
        let eco = try store.upsertMoodleCourse(moodleId: 1, name: "Fundamentals of Economics", code: "BHC1-03-045", start: nil, end: nil, hidden: false).id
        let mkt = try store.upsertMoodleCourse(moodleId: 2, name: "Mkt Hosp Ind", code: "BHC1-03-050", start: nil, end: nil, hidden: false).id
        _ = try store.db.execute("UPDATE courses SET book_title = 'Marketing for the Hospitality Industry' WHERE id = ?", [mkt])
        return (store, eco, mkt)
    }

    func testTheWeekMergesClassesAndDeadlinesByDay() throws {
        let (store, eco, mkt) = try makeStore()
        let now = at("2026-10-19", "08:00")
        try store.upsertDeadline(courseId: mkt, uid: "a", title: "Pricing report", kind: "assignment", due: at("2026-10-21", "23:59"), url: "https://moodle/a", submitted: false)
        try store.upsertDeadline(courseId: eco, uid: "b", title: "Problem set 3", kind: "assignment", due: at("2026-10-16", "17:00"), url: nil, submitted: false)
        try store.upsertDeadline(courseId: eco, uid: "c", title: "Problem set 4", kind: "assignment", due: at("2026-10-20", "17:00"), url: nil, submitted: true)
        let classes = Timetable.occurrences(try ICS.parse(timetable), from: d("2026-10-19"), to: d("2026-10-25"), tz: madrid)
        let week = Agenda.week(classes: classes, deadlines: store.upcomingDeadlines(now: now), courses: store.courses(), now: now, tz: madrid)

        XCTAssertEqual(week.overdue.map(\.title), ["Problem set 3"])
        XCTAssertEqual(week.days.map(\.date), [d("2026-10-19"), d("2026-10-21"), d("2026-10-22"), d("2026-10-23")], "empty days are left out")
        XCTAssertEqual(week.days[1].items.map(\.title), ["Fundamentals of Economics - Lecture", "Pricing report"], "in time order")
        XCTAssertEqual(week.days[1].items.map(\.kind), [.lesson, .deadline])
        XCTAssertEqual(week.days[0].items.first?.courseId, eco, "a class takes its course's colour by name")
        XCTAssertEqual(week.days[2].items.first?.courseId, mkt, "or by the book's title")
        XCTAssertNil(week.days[3].items.first?.courseId, "events that aren't a course stay grey")
        XCTAssertTrue(week.days[3].items[0].allDay)
        XCTAssertFalse(week.days.flatMap(\.items).contains { $0.title == "Problem set 4" }, "handed-in work isn't shown")

        // A deadline the calendar also carries shows once.
        let dup = Timetable.Instance(uid: "x", summary: "Pricing report is due", start: at("2026-10-21", "23:59"), end: nil, allDay: false)
        let again = Agenda.week(classes: classes + [dup], deadlines: store.upcomingDeadlines(now: now), courses: store.courses(), now: now, tz: madrid)
        XCTAssertEqual(again.days[1].items.map(\.title), ["Fundamentals of Economics - Lecture", "Pricing report"])
        // A class merely sharing words with a deadline that day stays.
        let pricing = Timetable.Instance(uid: "y", summary: "Pricing", start: at("2026-10-21", "11:00"), end: at("2026-10-21", "12:00"), allDay: false)
        XCTAssertEqual(Agenda.week(classes: [pricing], deadlines: store.upcomingDeadlines(now: now), courses: store.courses(), now: now, tz: madrid)
            .days.first { $0.date == d("2026-10-21") }?.items.map(\.title), ["Pricing", "Pricing report"])
    }

    func testLinks() async throws {
        XCTAssertEqual(TimetableFeed.normalize(" webcal://outlook.office365.com/owa/calendar/x/calendar.ics ")?.absoluteString,
                       "https://outlook.office365.com/owa/calendar/x/calendar.ics")
        XCTAssertNil(TimetableFeed.normalize("outlook calendar"))
        XCTAssertNil(TimetableFeed.normalize("file:///Users/me/cal.ics"))

        let t = FakeTransport()
        let url = URL(string: "https://example.com/cal.ics")!
        t.responses = [(200, [:], timetable), (200, [:], "<html>Calendar</html>"), (404, [:], "")]
        let ok = try await TimetableFeed.fetch(url, transport: t)
        XCTAssertEqual(ok.events, 5)
        do { _ = try await TimetableFeed.fetch(url, transport: t); XCTFail() } catch { XCTAssertEqual(error as? TimetableFeed.Failure, .notCalendar) }
        do { _ = try await TimetableFeed.fetch(url, transport: t); XCTFail() } catch { XCTAssertEqual(error as? TimetableFeed.Failure, .http(404)) }

        // Moodle's calendar export isn't a timetable.
        let moodle = URL(string: "https://elearning.example.edu/calendar/export_execute.php?userid=1&authtoken=x&preset_what=all")!
        do { _ = try await TimetableFeed.fetch(moodle, transport: t); XCTFail() } catch { XCTAssertEqual(error as? TimetableFeed.Failure, .moodleCalendar) }
        t.responses = [(200, [:], "BEGIN:VCALENDAR\nPRODID:-//Moodle Pty Ltd//NONSGML Moodle Version 2024100715//EN\nEND:VCALENDAR")]
        do { _ = try await TimetableFeed.fetch(url, transport: t); XCTFail() } catch { XCTAssertEqual(error as? TimetableFeed.Failure, .moodleCalendar) }

        let store = try BookStore.inMemory()
        store.saveTimetable(ok.text, events: ok.events, now: at("2026-10-19", "08:00"))
        XCTAssertEqual(store.classes(from: d("2026-10-19"), to: d("2026-10-19"), tz: madrid).count, 1)
        store.clearTimetable()
        XCTAssertTrue(store.classes(from: d("2026-10-19"), to: d("2026-10-25"), tz: madrid).isEmpty)
    }

    func testTheDeadlinesCalendarMatchesWhatsDue() throws {
        let (store, eco, mkt) = try makeStore()
        let now = at("2026-10-19", "08:00")
        try store.upsertDeadline(courseId: mkt, uid: "a", title: "Pricing report", kind: "assignment", due: at("2026-10-21", "23:59"), url: "https://moodle/a", submitted: false, now: now)
        try store.upsertDeadline(courseId: eco, uid: "b", title: "Problem set 4", kind: "assignment", due: at("2026-11-02", "17:00"), url: nil, submitted: false, now: now)
        try store.upsertDeadline(courseId: eco, uid: "c", title: "Old quiz", kind: "quiz", due: at("2026-09-01", "17:00"), url: nil, submitted: false, now: now)

        let entries = CalendarMirror.entries(deadlines: store.deadlinesToMirror(now: now), courses: store.courses())
        XCTAssertEqual(entries.map(\.title), ["Pricing report · Marketing for the Hospitality Industry", "Problem set 4 · Fundamentals of Economics"],
                       "work long overdue is left alone")

        // First run: everything is made, and a stray event in the app's calendar goes.
        let first = CalendarMirror.plan(entries: entries, stored: store.mirrorState(), inCalendar: ["stray"])
        XCTAssertEqual(first.create.count, 2)
        XCTAssertEqual(first.delete, ["stray"])
        for (i, e) in first.create.enumerated() { store.setMirrored(e.deadlineId, eventId: "ev\(i)", fingerprint: e.fingerprint) }

        // Nothing changed: nothing to do.
        XCTAssertTrue(CalendarMirror.plan(entries: entries, stored: store.mirrorState(), inCalendar: ["ev0", "ev1"]).isEmpty)

        // The report moves, problem set 4 is handed in, and the student deleted nothing.
        try store.upsertDeadline(courseId: mkt, uid: "a", title: "Pricing report", kind: "assignment", due: at("2026-10-23", "23:59"), url: "https://moodle/a", submitted: false, now: now)
        try store.upsertDeadline(courseId: eco, uid: "b", title: "Problem set 4", kind: "assignment", due: at("2026-11-02", "17:00"), url: nil, submitted: true, now: now)
        let later = CalendarMirror.entries(deadlines: store.deadlinesToMirror(now: now), courses: store.courses())
        let plan = CalendarMirror.plan(entries: later, stored: store.mirrorState(), inCalendar: ["ev0", "ev1"])
        XCTAssertEqual(plan.update.map(\.eventId), ["ev0"])
        XCTAssertEqual(plan.delete, ["ev1"])
        XCTAssertTrue(plan.create.isEmpty)

        // An event the student deleted is made again.
        XCTAssertEqual(CalendarMirror.plan(entries: later, stored: store.mirrorState(), inCalendar: []).create.count, 1)
    }
}
