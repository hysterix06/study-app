import XCTest
@testable import StudyCore

final class MoodleTests: XCTestCase {
    func reply(_ payload: String, scheme: String = "moodlemobile") -> URL {
        URL(string: "\(scheme)://token=" + Data(payload.utf8).base64EncodedString())!
    }

    func testLaunchURLAsksForTheMobileService() {
        let url = MoodleClient.launchURL(site: URL(string: "https://moodle.school.edu/lms")!, passport: "p123")
        XCTAssertEqual(url.absoluteString,
                       "https://moodle.school.edu/lms/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=p123&urlscheme=moodlemobile")
    }

    func testReadsTokenWithAndWithoutPrivateToken() throws {
        XCTAssertEqual(try MoodleClient.token(fromLaunchReply: reply("0a1b2c:::f00dcafe1234")), "f00dcafe1234")
        XCTAssertEqual(try MoodleClient.token(fromLaunchReply: reply("0a1b2c:::f00dcafe1234:::privKEY99")), "f00dcafe1234")
    }

    func testToleratesBrandedSchemesEncodingAndMissingPadding() throws {
        XCTAssertEqual(try MoodleClient.token(fromLaunchReply: reply("sig:::abc123", scheme: "myschoolapp")), "abc123")
        let b64 = Data("sig:::abc1".utf8).base64EncodedString()   // "c2lnOjo6YWJjMQ=="
        let encoded = b64.replacingOccurrences(of: "=", with: "%3D")
        XCTAssertEqual(try MoodleClient.token(fromLaunchReply: URL(string: "moodlemobile://token=\(encoded)")!), "abc1")
        let unpadded = b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        XCTAssertEqual(try MoodleClient.token(fromLaunchReply: URL(string: "moodlemobile://token=\(unpadded)")!), "abc1")
    }

    func testTellsSignInPagesFromWhereSignInLands() {
        let site = URL(string: "https://elearning.school.es")!
        func signIn(_ s: String, _ site: URL = site) -> Bool { MoodleClient.isSignInPage(URL(string: s)!, site: site) }
        XCTAssertTrue(signIn("https://elearning.school.es/login/index.php"))
        XCTAssertTrue(signIn("https://elearning.school.es/login/index.php?testsession=42"))
        XCTAssertTrue(signIn("https://elearning.school.es/auth/oidc/?source=loginpage"))
        XCTAssertTrue(signIn("https://elearning.school.es/admin/tool/mobile/launch.php?service=moodle_mobile_app"))
        XCTAssertTrue(signIn("https://login.microsoftonline.com/common/oauth2/authorize"))
        XCTAssertFalse(signIn("https://elearning.school.es/my/"))
        XCTAssertFalse(signIn("https://elearning.school.es/"))
        XCTAssertFalse(signIn("https://ELEARNING.school.es/course/view.php?id=3"))
        XCTAssertFalse(signIn("https://elearning.school.es/loginhelp.php"))
        let sub = URL(string: "https://school.es/moodle")!
        XCTAssertTrue(signIn("https://school.es/moodle/login/index.php", sub))
        XCTAssertFalse(signIn("https://school.es/moodle/my/", sub))
    }

    func testReadsTheSiteProfileBeforeSignIn() throws {
        let json = """
        [{"error":false,"data":{"wwwroot":"https://elearning.school.es","httpswwwroot":"https://elearning.school.es",
          "sitename":"Les Roches &amp; Co","enablewebservices":1,"enablemobilewebservice":1,"typeoflogin":1,
          "logourl":"https://elearning.school.es/logo.png","compactlogourl":"https://elearning.school.es/compact.png",
          "identityproviders":[{"name":"Microsoft Office 365","url":"https://elearning.school.es/auth/oidc/?source=loginpage"}]}}]
        """
        let p = try XCTUnwrap(MoodleSiteProfile(publicConfig: Data(json.utf8), site: URL(string: "https://typed.example")!))
        XCTAssertEqual(p.site.absoluteString, "https://elearning.school.es")
        XCTAssertEqual(p.name, "Les Roches & Co")
        XCTAssertEqual(p.logoURL?.lastPathComponent, "compact.png")
        XCTAssertEqual(p.providerName, "Microsoft Office 365")
        XCTAssertEqual(p.providerURL?.path, "/auth/oidc")
        XCTAssertTrue(p.appAccess)
    }

    func testSiteProfileFlagsClosedAccessAndDistrustsOffSiteButtons() throws {
        let json = """
        [{"error":false,"data":{"wwwroot":"https://m.school.edu","sitename":"School","enablewebservices":1,"enablemobilewebservice":0,
          "identityproviders":[{"name":"Elsewhere","url":"https://evil.example/login"}]}}]
        """
        let p = try XCTUnwrap(MoodleSiteProfile(publicConfig: Data(json.utf8), site: URL(string: "https://m.school.edu")!))
        XCTAssertFalse(p.appAccess)
        XCTAssertEqual(p.providerName, "Elsewhere")
        XCTAssertNil(p.providerURL)
        XCTAssertNil(MoodleSiteProfile(publicConfig: Data(#"[{"error":true,"exception":{}}]"#.utf8), site: URL(string: "https://x.edu")!))
        XCTAssertNil(MoodleSiteProfile(publicConfig: Data("<html>not moodle</html>".utf8), site: URL(string: "https://x.edu")!))
    }

    func testStatsCountWhatTheConnectionBroughtIn() throws {
        let store = try makeStore()
        let ids = try seedCourses(store)
        var hm = try XCTUnwrap(store.course(ids.hm))
        hm.moodleId = 101
        _ = try store.saveCourse(hm)
        _ = try store.saveAssignment(Assignment(courseId: ids.hm, title: "Case study", kind: .assignment, dueAt: nil, confirmed: true,
                                                source: "moodle", externalUid: "assign:1"), markModified: false)
        var graded = Assignment(courseId: ids.hm, title: "Quiz 1", kind: .quiz, dueAt: nil, confirmed: true, source: "moodle", externalUid: "quiz:2")
        graded.status = .graded
        _ = try store.saveAssignment(graded, markModified: false)
        _ = try store.saveAssignment(Assignment(courseId: ids.mkt, title: "Typed by hand", kind: .assignment, dueAt: nil, confirmed: true),
                                     markModified: true)
        XCTAssertEqual(MoodleSync.stats(store: store), MoodleStats(courses: 1, deadlines: 2, grades: 1, files: 0))
    }

    func testRejectsRepliesWithoutAToken() {
        XCTAssertThrowsError(try MoodleClient.token(fromLaunchReply: URL(string: "moodlemobile://other=1")!))
        XCTAssertThrowsError(try MoodleClient.token(fromLaunchReply: reply("no separator here")))
        XCTAssertThrowsError(try MoodleClient.token(fromLaunchReply: reply("sig:::")))
        XCTAssertThrowsError(try MoodleClient.token(fromLaunchReply: reply("sig:::<script>")))
    }
}

extension MoodleTests {
    func testCreatesCurrentCoursesAndTermFromMoodle() throws {
        let store = try makeStore()
        let now = at("2026-09-15", "12:00")
        let sep = at("2026-09-07", "00:00").timeIntervalSince1970, dec = at("2026-12-18", "00:00").timeIntervalSince1970
        store.setSetting("moodle_courses", JSON.string([
            ["id": 11, "shortname": "HM210", "fullname": "Revenue Management", "startdate": Int(sep), "enddate": Int(dec)],
            ["id": 12, "shortname": "MKT201", "fullname": "Hospitality Marketing", "startdate": Int(sep), "enddate": 0],
            ["id": 9, "shortname": "OLD100", "fullname": "Last year", "startdate": Int(sep) - 31_536_000, "enddate": Int(sep) - 20_000_000],
        ]))
        let r = try MoodleSync.createCoursesAndTerm(store: store, now: now)
        XCTAssertTrue(r.termCreated)
        XCTAssertEqual(r.courses, 2)
        let term = try XCTUnwrap(store.currentTerm())
        XCTAssertEqual(term.name, "Fall 2026")
        XCTAssertEqual(term.startDate, d("2026-09-07"))
        XCTAssertEqual(term.endDate, d("2026-12-18"))
        XCTAssertEqual(Set(store.courses().compactMap(\.moodleId)), [11, 12])
        XCTAssertEqual(Set(store.courses().map(\.color)).count, 2, "each course gets its own color")
        // Running again creates nothing new.
        XCTAssertEqual(try MoodleSync.createCoursesAndTerm(store: store, now: now).courses, 0)
    }
}
