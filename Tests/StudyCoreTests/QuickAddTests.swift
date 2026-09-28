import XCTest
@testable import StudyCore

final class QuickAddTests: XCTestCase {
    // Monday 28 September 2026, noon in Madrid.
    let now = at("2026-09-28", "12:00")
    let courses = [
        Course(id: 1, termId: 1, code: "HM210", name: "Revenue Management", aliases: "revman, rm"),
        Course(id: 2, termId: 1, code: "MKT201", name: "Hospitality Marketing"),
        Course(id: 3, termId: 1, code: "FIN200", name: "Hospitality Finance"),
        Course(id: 4, termId: 1, code: nil, name: "Wine Studies"),
    ]

    func parse(_ s: String, dayFirst: Bool = true) -> QuickAddResult {
        QuickAddParser(courses: courses, now: now, tz: madrid, dayFirst: dayFirst).parse(s)
    }

    func due(_ r: QuickAddResult) -> String? {
        r.dueAt.map { "\(LocalDate($0, tz: madrid).string) \(LocalTime($0, tz: madrid).string)" }
    }

    func testSpecExample() {
        let r = parse("Marketing report MKT210 fri 5pm 30% 6h")
        // MKT210 is not a course code here, so no course; the rest parses.
        XCTAssertEqual(due(r), "2026-10-02 17:00")
        XCTAssertEqual(r.weightPct, 30)
        XCTAssertEqual(r.estHours, 6)
        XCTAssertEqual(r.kind, .report)
    }

    func testSpecExampleWithRealCode() {
        let r = parse("Marketing report MKT201 fri 5pm 30% 6h")
        XCTAssertEqual(r.title, "Marketing report")
        XCTAssertEqual(r.courseId, 2)
        XCTAssertEqual(due(r), "2026-10-02 17:00")
        XCTAssertEqual(r.weightPct, 30)
        XCTAssertEqual(r.estHours, 6)
        XCTAssertFalse(r.needsCoursePick)
    }

    func testPhrases() {
        let cases: [(String, String?, Int?, Double?, Double?, String?)] = [
            // input, due, course, weight, hours, title
            ("Pricing memo HM210 tomorrow", "2026-09-29 23:59", 1, nil, nil, "Pricing memo"),
            ("Pricing memo hm210 tomorrow 9am", "2026-09-29 09:00", 1, nil, nil, "Pricing memo"),
            ("Pricing memo HM 210 tmrw", "2026-09-29 23:59", 1, nil, nil, "Pricing memo"),
            ("Case prep revman wed", "2026-09-30 23:59", 1, nil, nil, "Case prep"),
            ("Case prep #HM210 thursday 14:30", "2026-10-01 14:30", 1, nil, nil, "Case prep"),
            ("Budget FIN200 next fri", "2026-10-09 23:59", 3, nil, nil, "Budget"),
            ("Budget FIN200 in 3 days", "2026-10-01 23:59", 3, nil, nil, "Budget"),
            ("Budget FIN200 in 2 weeks", "2026-10-12 23:59", 3, nil, nil, "Budget"),
            ("Budget FIN200 in a week", "2026-10-05 23:59", 3, nil, nil, "Budget"),
            ("Reflection MKT201 Oct 12", "2026-10-12 23:59", 2, nil, nil, "Reflection"),
            ("Reflection MKT201 October 12th 10am", "2026-10-12 10:00", 2, nil, nil, "Reflection"),
            ("Reflection MKT201 12 Oct", "2026-10-12 23:59", 2, nil, nil, "Reflection"),
            ("Reflection MKT201 12th of October 2026", "2026-10-12 23:59", 2, nil, nil, "Reflection"),
            ("Reflection MKT201 2026-11-03", "2026-11-03 23:59", 2, nil, nil, "Reflection"),
            ("Reflection MKT201 3/11", "2026-11-03 23:59", 2, nil, nil, "Reflection"),
            ("Reflection MKT201 3.11.", "2026-11-03 23:59", 2, nil, nil, "Reflection"),
            ("Reflection MKT201 25/9", "2027-09-25 23:59", 2, nil, nil, "Reflection"),
            ("Old item MKT201 Jan 5", "2027-01-05 23:59", 2, nil, nil, "Old item"),
            ("Essay HM210 due fri by 5pm", "2026-10-02 17:00", 1, nil, nil, "Essay"),
            ("Essay HM210 fri 5:30 pm", "2026-10-02 17:30", 1, nil, nil, "Essay"),
            ("Essay HM210 fri noon", "2026-10-02 12:00", 1, nil, nil, "Essay"),
            ("Essay HM210 fri at 3", "2026-10-02 15:00", 1, nil, nil, "Essay"),
            ("Essay HM210 today", "2026-09-28 23:59", 1, nil, nil, "Essay"),
            ("Essay HM210 5pm", "2026-09-28 17:00", 1, nil, nil, "Essay"),
            ("Essay HM210 9am", "2026-09-29 09:00", 1, nil, nil, "Essay"),
            ("Essay HM210 mon 10am", "2026-10-05 10:00", 1, nil, nil, "Essay"),
            ("Group project MKT201 25% 10 hours nov 20", "2026-11-20 23:59", 2, 25, 10, "Group project"),
            ("Group project MKT201 12.5% 1.5h", nil, 2, 12.5, 1.5, "Group project"),
            ("Group project MKT201 90 min", nil, 2, nil, 1.5, "Group project"),
            ("  weird    spacing   HM210    fri   ", "2026-10-02 23:59", 1, nil, nil, "weird spacing"),
            ("Tasting notes Wine Studies thu", "2026-10-01 23:59", 4, nil, nil, "Tasting notes Wine Studies"),
            ("Read chapter 4 rm", nil, 1, nil, nil, "Read chapter 4"),
            ("No course at all fri", "2026-10-02 23:59", nil, nil, nil, "No course at all"),
        ]
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        for (input, dueS, course, weight, hours, title) in cases {
            let r = parse(input)
            XCTAssertEqual(due(r), dueS, "due for \(input)")
            XCTAssertEqual(r.courseId, course, "course for \(input)")
            XCTAssertEqual(r.weightPct, weight, "weight for \(input)")
            XCTAssertEqual(r.estHours, hours, "hours for \(input)")
            if let title { XCTAssertEqual(r.title, title, "title for \(input)") }
        }
    }

    func testAmbiguousCourseNeedsPick() {
        let r = parse("Hospitality reading fri")
        XCTAssertNil(r.courseId)
        XCTAssertEqual(Set(r.courseCandidates), [2, 3])
        XCTAssertTrue(r.needsCoursePick)
    }

    func testKinds() {
        XCTAssertEqual(parse("Midterm exam FIN200 oct 20 9am").kind, .exam)
        XCTAssertEqual(parse("Week 3 quiz HM210").kind, .quiz)
        XCTAssertEqual(parse("Pitch presentation MKT201").kind, .presentation)
        XCTAssertEqual(parse("Reading ch 2 HM210").kind, .reading)
        XCTAssertEqual(parse("Case study HM210").kind, .case_)
        XCTAssertEqual(parse("Midterm exam FIN200 oct 20 9am").title, "Midterm exam", "kind words stay in the title")
    }

    func testMonthFirstPreference() {
        let r = parse("Reflection MKT201 3/11", dayFirst: false)
        XCTAssertEqual(due(r), "2027-03-11 23:59")
    }

    func testChipsAreProduced() {
        let r = parse("Marketing report MKT201 fri 5pm 30% 6h")
        XCTAssertEqual(r.pieces.map(\.kind), [.course, .weight, .hours, .due, .kind])
    }
}
