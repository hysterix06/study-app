import XCTest
@testable import StudyCore

final class RouteTests: XCTestCase {
    /// One example per row of the route table in docs/UI-screens-plan.md.
    let documented: [(String, Route)] = [
        ("today", .today),
        ("inbox", .inbox(nil)),
        ("inbox/cards", .inbox(.cards)),
        ("calendar/month/2026-10-05", .calendar(.month, LocalDate("2026-10-05"))),
        ("calendar/occurrence/p12:2026-09-30", .occurrence("p12:2026-09-30")),
        ("calendar/occurrence/b7", .occurrence("b7")),
        ("assignments", .assignments),
        ("assignment/42", .assignment(42)),
        ("course/3/materials", .course(3, .materials)),
        ("material/9", .material(9)),
        ("study/insights", .study(.insights)),
        ("review", .review(courseId: nil)),
        ("review/course/3", .review(courseId: 3)),
        ("connections", .connections(nil)),
        ("connections/moodle", .connections(.moodle)),
        ("activity", .activity(jobId: nil)),
        ("activity/17", .activity(jobId: 17)),
        ("settings/appearance", .settings(.appearance)),
        ("setup/timetable", .setup(.timetable)),
    ]

    func testDocumentedPathsParse() {
        for (path, route) in documented {
            XCTAssertEqual(Route(path: path), route, path)
            XCTAssertEqual(route.path, path, path)
        }
    }

    func testEveryCaseRoundTripsThroughPathAndURL() {
        var routes: [Route] = [.today, .inbox(nil), .assignments, .connections(nil), .activity(jobId: nil), .review(courseId: nil)]
        routes += InboxSection.allCases.map { .inbox($0) }
        routes += CalendarMode.allCases.flatMap { [Route.calendar($0, nil), .calendar($0, LocalDate("2026-02-28"))] }
        routes += CourseTab.allCases.map { .course(5, $0) }
        routes += StudySegment.allCases.map { .study($0) }
        routes += ConnectionKind.allCases.map { .connections($0) }
        routes += SettingsPane.allCases.map { .settings($0) }
        routes += SetupStep.allCases.map { .setup($0) }
        routes += [.occurrence("e5"), .assignment(1), .material(2), .review(courseId: 4), .activity(jobId: 8)]
        for r in routes {
            XCTAssertEqual(Route(path: r.path), r, r.path)
            XCTAssertEqual(Route(url: r.url), r, r.url.absoluteString)
        }
    }

    func testURLs() {
        XCTAssertEqual(Route.course(3, .cards).url.absoluteString, "studytracker://course/3/cards")
        XCTAssertEqual(Route(url: URL(string: "studytracker://settings/appearance")!), .settings(.appearance))
        XCTAssertEqual(Route(url: URL(string: "STUDYTRACKER://today")!), .today)
        XCTAssertNil(Route(url: URL(string: "https://today")!))
    }

    func testDefaultsAndBadInput() {
        XCTAssertEqual(Route(path: "course/3"), .course(3, .overview))
        XCTAssertEqual(Route(path: "calendar"), .calendar(.week, nil))
        XCTAssertEqual(Route(path: "/today/"), .today)
        for bad in ["", "nowhere", "course/x", "course/3/nope", "calendar/week/2026-02-31", "inbox/nope", "assignment",
                    "settings/moodle", "today/extra", "review/course"] {
            XCTAssertNil(Route(path: bad), bad)
        }
    }

    func testScreenKeys() {
        XCTAssertEqual(Route.occurrence("e1").screen, .calendar)
        XCTAssertEqual(Route.assignment(1).screen, .assignments)
        XCTAssertEqual(Route.course(2, .cards).screen, .course(2))
        XCTAssertEqual(Route.material(3).screen, .study)
    }
}
