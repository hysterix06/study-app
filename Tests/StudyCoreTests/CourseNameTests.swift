import XCTest
@testable import StudyCore

final class CourseNameTests: XCTestCase {
    func testDisplayPriorityIsShortNameThenNameThenCode() {
        let full = Course(termId: 1, code: "HM230", name: "Hospitality Financial Accounting", shortName: "Accounting")
        XCTAssertEqual(full.displayName, "Accounting")
        XCTAssertEqual(full.secondaryName, "Hospitality Financial Accounting")
        XCTAssertEqual(full.names, ["Accounting", "Hospitality Financial Accounting", "HM230"])

        let noShort = Course(termId: 1, code: "HM230", name: "Hospitality Financial Accounting", shortName: "  ")
        XCTAssertEqual(noShort.displayName, "Hospitality Financial Accounting")
        XCTAssertEqual(noShort.secondaryName, "HM230")

        let codeOnly = Course(termId: 1, code: "HM230", name: "")
        XCTAssertEqual(codeOnly.displayName, "HM230")
        XCTAssertNil(codeOnly.secondaryName)

        let same = Course(termId: 1, code: nil, name: "Wine Studies", shortName: "Wine Studies")
        XCTAssertEqual(same.names, ["Wine Studies"], "repeats collapse")
    }

    func testFolderNameIgnoresShortName() {
        let c = Course(termId: 1, code: "HM230", name: "Hospitality Financial Accounting", shortName: "Accounting")
        XCTAssertEqual(c.codeOrName, "HM230")
    }

    func testShortNameRoundTripsAndSortsCourses() throws {
        let store = try makeStore()
        let (term, hm, mkt) = try seedCourses(store)
        let acc = try store.saveCourse(Course(termId: term, code: "HM230", name: "Hospitality Financial Accounting", shortName: " Accounting "))
        XCTAssertEqual(store.course(acc)?.shortName, "Accounting", "trimmed on save")
        XCTAssertNil(store.course(hm)?.shortName)

        // Sorted by what the list shows: Accounting, Hospitality Marketing, Revenue Management.
        XCTAssertEqual(store.courses().map(\.id), [acc, mkt, hm])

        var c = store.course(acc)!
        c.shortName = ""
        try store.saveCourse(c)
        XCTAssertNil(store.course(acc)?.shortName, "clearing it stores NULL")
        XCTAssertEqual(store.course(acc)?.displayName, "Hospitality Financial Accounting")
    }

    func testShortNameMatchesLikeAnAlias() {
        let courses = [Course(id: 1, termId: 1, code: "HM230", name: "Hospitality Financial Accounting", shortName: "Accounting"),
                       Course(id: 2, termId: 1, code: "MKT201", name: "Hospitality Marketing")]
        let r = QuickAddParser(courses: courses, now: at("2026-09-28", "12:00"), tz: madrid, dayFirst: true).parse("Ratio worksheet accounting fri")
        XCTAssertEqual(r.courseId, 1)
        XCTAssertEqual(r.title, "Ratio worksheet")
        XCTAssertEqual(CourseMatcher.best("Accounting tutorial slides", courses: courses)?.id, 1)
    }
}
