import XCTest
@testable import StudyCore

final class RouteTests: XCTestCase {
    /// One example per screen.
    let documented: [(String, Route)] = [
        ("home", .home),
        ("needs-a-look", .needsLook),
        ("calendar/month/2026-10-05", .calendar(.month, LocalDate("2026-10-05"))),
        ("calendar/occurrence/p12:2026-09-30", .occurrence("p12:2026-09-30")),
        ("calendar/occurrence/b7", .occurrence("b7")),
        ("assignments", .assignments),
        ("assignment/42", .assignment(42)),
        ("course/3/notebook", .course(3, .notebook)),
        ("course/3/angles", .course(3, .angles)),
        ("topic/12", .topic(12)),
        ("file/9", .material(9)),
        ("settings/ai", .settings(.ai)),
        ("settings/connections", .settings(.connections)),
        ("setup/school", .setup(.school)),
    ]

    func testDocumentedPathsParse() {
        for (path, route) in documented {
            XCTAssertEqual(Route(path: path), route, path)
            XCTAssertEqual(route.path, path, path)
        }
    }

    func testEveryCaseRoundTripsThroughPathAndURL() {
        var routes: [Route] = [.home, .needsLook, .assignments, .topic(4), .material(2), .occurrence("e5"), .assignment(1)]
        routes += CalendarMode.allCases.flatMap { [Route.calendar($0, nil), .calendar($0, LocalDate("2026-02-28"))] }
        routes += CourseTab.allCases.map { .course(5, $0) }
        routes += SettingsPane.allCases.map { .settings($0) }
        routes += SetupStep.allCases.map { .setup($0) }
        for r in routes {
            XCTAssertEqual(Route(path: r.path), r, r.path)
            XCTAssertEqual(Route(url: r.url), r, r.url.absoluteString)
        }
    }

    /// Links from older versions (notifications, bookmarks, other apps) open the screen that replaced theirs.
    func testOldLinksOpenTheirNewHomes() {
        let old: [(String, Route)] = [
            ("today", .home), ("study", .home), ("study/insights", .home), ("review", .home), ("review/course/3", .home),
            ("inbox", .needsLook), ("inbox/cards", .needsLook),
            ("material/9", .material(9)),
            ("connections", .settings(.connections)), ("connections/moodle", .settings(.connections)),
            ("connections/ai", .settings(.ai)), ("connections/claude", .settings(.ai)),
            ("activity", .settings(.ai)), ("activity/17", .settings(.ai)),
            ("course/3/materials", .course(3, .files)), ("course/3/assignments", .course(3, .deadlines)),
            ("course/3/overview", .course(3, .path)), ("course/3/cards", .course(3, .path)), ("course/3/concepts", .course(3, .path)),
            ("settings/planner", .settings(.study)),
            ("setup/moodle", .setup(.school)), ("setup/timetable", .setup(.school)), ("setup/claude", .setup(.ai)), ("setup/files", .setup(.done)),
        ]
        for (path, route) in old { XCTAssertEqual(Route(path: path), route, path) }
    }

    func testURLs() {
        XCTAssertEqual(Route.course(3, .notebook).url.absoluteString, "studytracker://course/3/notebook")
        XCTAssertEqual(Route(url: URL(string: "studytracker://settings/appearance")!), .settings(.appearance))
        XCTAssertEqual(Route(url: URL(string: "STUDYTRACKER://today")!), .home)
        XCTAssertNil(Route(url: URL(string: "https://today")!))
    }

    func testDefaultsAndBadInput() {
        XCTAssertEqual(Route(path: "course/3"), .course(3, .path))
        XCTAssertEqual(Route(path: "calendar"), .calendar(.week, nil))
        XCTAssertEqual(Route(path: "/home/"), .home)
        for bad in ["", "nowhere", "course/x", "course/3/nope", "calendar/week/2026-02-31", "inbox/nope", "assignment",
                    "settings/moodle", "today/extra", "review/course", "topic/x"] {
            XCTAssertNil(Route(path: bad), bad)
        }
    }

    func testScreenKeys() {
        XCTAssertEqual(Route.occurrence("e1").screen, .schedule)
        XCTAssertEqual(Route.assignment(1).screen, .schedule)
        XCTAssertEqual(Route.course(2, .files).screen, .course(2))
        XCTAssertEqual(Route.needsLook.screen, .home)
    }
}
