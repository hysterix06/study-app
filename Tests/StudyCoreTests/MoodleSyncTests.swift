import XCTest
@testable import StudyCore

/// A Moodle that answers web service calls and file downloads from a script.
final class FakeMoodle: URLProtocol {
    nonisolated(unsafe) static var functions: [String: (([String: String]) -> Any)] = [:]
    nonisolated(unsafe) static var files: [String: String] = [:]
    nonisolated(unsafe) static var calls: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        var status = 200, body = Data()
        if url.path.hasSuffix("webservice/rest/server.php") {
            let form = Self.form(Self.body(of: request))
            let name = form["wsfunction"] ?? ""
            Self.lock.withLock { Self.calls.append(name) }
            if let f = Self.functions[name] { body = try! JSONSerialization.data(withJSONObject: f(form), options: [.fragmentsAllowed]) }
            else { body = Data(#"{"exception":"x","errorcode":"invalidrecord","message":"no \#(name)"}"#.utf8) }
        } else if let text = Self.files[url.path] {
            Self.lock.withLock { Self.calls.append(url.path) }
            body = Data(text.utf8)
        } else {
            status = 404
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func body(of r: URLRequest) -> String {
        if let b = r.httpBody { return String(decoding: b, as: UTF8.self) }
        guard let s = r.httpBodyStream else { return "" }
        s.open(); defer { s.close() }
        var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        return String(decoding: data, as: UTF8.self)
    }

    static func form(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    static func client() -> MoodleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeMoodle.self]
        var c = MoodleClient(site: URL(string: "https://moodle.test")!, token: "t0k")
        c.session = URLSession(configuration: config)
        return c
    }
}

final class MoodleSyncTests: XCTestCase {
    let now = ISO.parse("2026-10-16T10:00:00Z")!
    func ts(_ days: Double) -> Int { Int(now.addingTimeInterval(days * 86_400).timeIntervalSince1970) }

    override func setUp() {
        let stale = Int(ISO.parse("2025-09-04T00:00:00Z")!.timeIntervalSince1970), ended = Int(ISO.parse("2026-03-01T00:00:00Z")!.timeIntervalSince1970)
        FakeMoodle.calls = []
        FakeMoodle.functions = [
            "core_webservice_get_site_info": { _ in ["userid": 7, "fullname": "Test Student", "sitename": "Test <b>Moodle</b>"] },
            "core_enrol_get_users_courses": { _ in [
                ["id": 11, "shortname": "HM210 26.2", "fullname": "HM210 Revenue Mgmt 26.2", "startdate": stale, "enddate": ended],
                ["id": 12, "shortname": "BHC1-09-158 26.2", "fullname": "BHC1-09-158 Mkt for the Hosp Ind 26.2", "startdate": stale, "enddate": 0],
                ["id": 13, "shortname": "academics 26.2", "fullname": "Academic Services 26.2", "startdate": stale, "enddate": 0],
                ["id": 14, "shortname": "OLD", "fullname": "Old elective 2026.1", "startdate": stale, "enddate": 0],
                ["id": 15, "shortname": "training", "fullname": "Moodle Exam Training", "startdate": 1_600_000_000, "enddate": 0],
            ] },
            "mod_assign_get_assignments": { _ in ["courses": [
                ["id": 11, "assignments": [["id": 101, "cmid": 9101, "name": "Pricing report", "duedate": self.ts(3)],
                                           ["id": 102, "cmid": 9102, "name": "Reflection", "duedate": self.ts(5)]]],
                ["id": 12, "assignments": [["id": 201, "cmid": 9201, "name": "Job description", "duedate": 0]]],
            ]] },
            "mod_assign_get_submission_status": { f in
                ["lastattempt": ["submission": ["status": f["assignid"] == "102" ? "submitted" : "new"]]]
            },
            "core_calendar_get_action_events_by_timesort": { _ in ["events": [
                ["modulename": "quiz", "instance": 301, "course": ["id": 12], "timesort": self.ts(2), "activityname": "Topic 3 quiz", "url": "https://moodle.test/q"],
                ["modulename": "assign", "instance": 101, "course": ["id": 11], "timesort": self.ts(3), "activityname": "Pricing report"],
            ]] },
            "core_course_get_contents": { f in
                func file(_ cmid: Int, _ module: String, _ name: String, modified: Int = 100) -> [String: Any] {
                    ["id": cmid, "modname": "resource", "name": module,
                     "contents": [["type": "file", "filename": name, "filepath": "/", "fileurl": "https://moodle.test/pluginfile.php/\(cmid)/\(name)", "filesize": 60, "timemodified": modified]]]
                }
                if f["courseid"] == "11" {
                    return [["name": "General", "modules": [file(501, "Course outline", "outline.txt")]],
                            ["name": "Week 1", "modules": [file(502, "Lecture 1: Pricing", "pricing.md", modified: FakeMoodle.pricingVersion),
                                                           ["id": 503, "modname": "url", "name": "A link"]]]]
                }
                return [["name": "Practice", "modules": [file(601, "Exercise 1", "exercise.txt")]]]
            },
        ]
        FakeMoodle.pricingVersion = 100
        FakeMoodle.files = [
            "/pluginfile.php/501/outline.txt": "Week 1 Pricing. Week 2 Distribution. Assessment: report 40%.",
            "/pluginfile.php/502/pricing.md": "# Pricing\n\nRevPAR combines occupancy and rate.\n\n# Overbooking\n\nNo-shows.",
            "/pluginfile.php/601/exercise.txt": "Calculate RevPAR for a 200-room hotel.",
        ]
    }

    func testSyncAddsThisTermsCoursesDeadlinesAndFilesThenChangesNothing() async throws {
        let store = try BookStore.inMemory()
        let first = await MoodleSync.run(store: store, client: FakeMoodle.client(), now: now)
        XCTAssertEqual(first.errors, [])
        XCTAssertEqual(first.coursesAdded, 3, "this term's three courses, whatever their stale dates say")
        XCTAssertEqual(store.courses().map(\.name), ["Mkt for the Hosp Ind", "Revenue Mgmt"], "the services page is added hidden")
        XCTAssertEqual(store.courses(includeHidden: true).count, 3)
        XCTAssertEqual(store.courses().first?.code, "BHC1-09-158")
        XCTAssertEqual(store.setting("moodle_site_name"), "Test Moodle")

        let hm = try XCTUnwrap(store.course(moodleId: 11)), mkt = try XCTUnwrap(store.course(moodleId: 12))
        XCTAssertEqual(first.deadlinesAdded, 4)
        XCTAssertEqual(store.upcomingDeadlines(now: now).map(\.title), ["Topic 3 quiz", "Pricing report"], "submitted and undated work isn't due")
        XCTAssertEqual(store.deadlines(courseId: hm.id).first { $0.title == "Reflection" }?.submitted, true)
        XCTAssertEqual(store.deadlines(courseId: hm.id).first?.url, "https://moodle.test/mod/assign/view.php?id=9101")

        let files = store.files(courseId: hm.id)
        XCTAssertEqual(files.map(\.title), ["Course outline", "Lecture 1: Pricing"], "only files, in course order")
        XCTAssertEqual(files.map(\.kind), ["syllabus", "lecture"])
        XCTAssertEqual(files[1].week, 1)
        XCTAssertEqual(files[1].headings, ["Pricing", "Overbooking"])
        XCTAssertTrue(files[1].text.contains("RevPAR combines occupancy"))
        XCTAssertEqual(store.files(courseId: mkt.id).map(\.kind), ["other"])
        XCTAssertFalse(FakeMoodle.calls.contains("/pluginfile.php/601/exercise.txt"), "exercises are listed, never downloaded")
        XCTAssertEqual(first.filesRead, 2)
        XCTAssertEqual(first.filesNoted, 1)
        XCTAssertNotNil(store.course(hm.id)?.filesSyncedAt)

        FakeMoodle.calls = []
        let second = await MoodleSync.run(store: store, client: FakeMoodle.client(), now: now.addingTimeInterval(60))
        XCTAssertFalse(second.changedAnything, "\(second)")
        XCTAssertEqual(second.summary, "Up to date")
        XCTAssertEqual(FakeMoodle.calls.filter { $0 == "core_course_get_contents" }.count, 2, "files of the hidden page aren't read")
    }

    func testWhatMoodleDropsGoesAndChangedFilesAreReadAgain() async throws {
        let store = try BookStore.inMemory()
        _ = await MoodleSync.run(store: store, client: FakeMoodle.client(), now: now)
        FakeMoodle.functions["mod_assign_get_assignments"] = { _ in ["courses": [
            ["id": 11, "assignments": [["id": 101, "cmid": 9101, "name": "Pricing report (final)", "duedate": self.ts(4)]]],
        ]] }
        FakeMoodle.pricingVersion = 200
        FakeMoodle.files["/pluginfile.php/502/pricing.md"] = "# Pricing\n\nUpdated slides."
        let r = await MoodleSync.run(store: store, client: FakeMoodle.client(), now: now.addingTimeInterval(3600))
        XCTAssertEqual(r.deadlinesChanged, 1)
        XCTAssertEqual(r.deadlinesRemoved, 2, "the reflection and the job description are gone from Moodle")
        XCTAssertEqual(r.filesRead, 1)
        let hm = try XCTUnwrap(store.course(moodleId: 11))
        XCTAssertTrue(store.files(courseId: hm.id)[1].text.contains("Updated slides"))
    }

    func testAnExpiredSignInIsReported() async throws {
        let store = try BookStore.inMemory()
        FakeMoodle.functions = ["core_webservice_get_site_info": { _ in ["exception": "x", "errorcode": "invalidtoken", "message": "Invalid token"] }]
        let r = await MoodleSync.run(store: store, client: FakeMoodle.client(), now: now)
        XCTAssertTrue(r.needsSignIn)
        XCTAssertEqual(store.setting("moodle_needs_signin"), "1")
    }
}

extension FakeMoodle {
    nonisolated(unsafe) static var pricingVersion = 100
}

final class MoodleCoursesTests: XCTestCase {
    func testNamesDropTheCodeAndTheTerm() {
        XCTAssertTrue(MoodleCourses.names(shortname: "BHC1-03-045 26.2", fullname: "BHC1-03-045 Fund of Economics 26.2") == ("Fund of Economics", "BHC1-03-045"))
        XCTAssertTrue(MoodleCourses.names(shortname: "HM210", fullname: "HM 210 Revenue Management (2026.1)") == ("Revenue Management", "HM210"))
        XCTAssertEqual(MoodleCourses.names(shortname: "sga", fullname: "SGA - Student Governance Association").name, "SGA - Student Governance Association")
    }

    func testTermsAndAdministrativePages() {
        XCTAssertEqual(MoodleCourses.term(MoodleCourseInfo(id: 1, shortname: "x 26.2", fullname: "X 26.2")), 20262)
        XCTAssertEqual(MoodleCourses.term(MoodleCourseInfo(id: 1, shortname: "y", fullname: "Academic Services 2026.1")), 20261)
        XCTAssertNil(MoodleCourses.term(MoodleCourseInfo(id: 1, shortname: "z", fullname: "Moodle Exam Training")))
        XCTAssertTrue(MoodleCourses.looksAdministrative("BSc1GHM_BBA3_DIP3 Induction 26.2"))
        XCTAssertFalse(MoodleCourses.looksAdministrative("Marketing for the Hospitality Industry"))
    }
}

final class FileKindTests: XCTestCase {
    func testSortsSyllabiLecturesAndTheRest() {
        XCTAssertEqual(FileKind.classify(name: "BHC1-09-158 SOW 2026.2.pdf", section: "Welcome!", module: nil).kind, "syllabus")
        XCTAssertEqual(FileKind.classify(name: "doc.pdf", section: nil, module: "Guía docente").kind, "syllabus")
        XCTAssertEqual(FileKind.classify(name: "x.pdf", section: nil, module: nil, text: "Course outline\nWeek 1 …").kind, "syllabus")
        XCTAssertEqual(FileKind.classify(name: "CH5 Marketing Information System.pptx", section: "CH5. Marketing Information System", module: nil).kind, "lecture")
        XCTAssertEqual(FileKind.classify(name: "OCT 2025 Exam Training.pdf", section: "Welcome!", module: nil).kind, "other")
        XCTAssertEqual(FileKind.classify(name: "PEST Analysis Worksheet.docx", section: "CH5", module: nil).kind, "other")
        XCTAssertEqual(FileKind.classify(name: "slides.pdf", section: "Week 7 - Pricing", module: nil).week, 7)
        XCTAssertEqual(FileKind.classify(name: "REPASO.pdf", section: "Semanas 1 y 2", module: nil).week, 1)
        XCTAssertNil(FileKind.classify(name: "CH5.pdf", section: "CH5", module: nil).week, "a chapter number isn't a week")
    }

    func testStoreOpensOnceAndAgain() throws {
        let root = FixtureFactory.tempDir()
        let paths = AppPaths(database: root.appendingPathComponent("book.db"), root: root)
        let store = try BookStore.open(paths: paths)
        XCTAssertEqual(try store.db.scalarInt("PRAGMA user_version"), BookStore.schemaVersion)
        let tables = Set(try store.db.query("SELECT name FROM sqlite_master WHERE type = 'table'").map { $0.str("name") })
        XCTAssertEqual(tables, ["settings", "courses", "files", "deadlines", "chapters", "cards", "reviews"])
        store.setSetting("x", "1")
        XCTAssertEqual(try BookStore.open(paths: paths).setting("x"), "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups").path))
    }
}
