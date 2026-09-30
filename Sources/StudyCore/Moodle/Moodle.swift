import Foundation

/// Read-only client for Moodle's mobile web services (the same API the official Moodle app uses).
/// The token lives in the Keychain. Nothing is written back to Moodle.
public struct MoodleClient {
    public let site: URL
    public let token: String
    public var session: URLSession = .shared

    public init(site: URL, token: String) { self.site = site; self.token = token }

    public struct MoodleError: Error, CustomStringConvertible {
        public let message: String
        /// Moodle's own error code, e.g. "invalidtoken" once the school ends the connection.
        public var code: String?
        public init(message: String, code: String? = nil) { self.message = message; self.code = code }
        public var description: String { message }
    }

    public static func normalizeSite(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        for suffix in ["/login/index.php", "/my", "/my/index.php", "/course/view.php"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        return URL(string: t)
    }

    /// Exchanges a username and password for a mobile-app token. The password is never stored.
    public static func requestToken(site: URL, username: String, password: String, session: URLSession = .shared) async throws -> String {
        var req = URLRequest(url: site.appendingPathComponent("login/token.php"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["username": username, "password": password, "service": "moodle_mobile_app"]).data(using: .utf8)
        let (data, _) = try await session.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MoodleError(message: "Moodle did not answer as expected. Check the site address.")
        }
        if let token = obj["token"] as? String { return token }
        let msg = obj["error"] as? String ?? "Moodle refused the sign-in."
        throw MoodleError(message: msg + " If your school signs in with Microsoft 365 or another single sign-on, choose \"Microsoft 365 / SSO\" instead.")
    }

    /// What a site says about itself before anyone signs in: the same call the official app makes first.
    public static func siteProfile(site: URL, session: URLSession = .shared) async throws -> MoodleSiteProfile {
        var comps = URLComponents(url: site.appendingPathComponent("lib/ajax/service-nologin.php"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "info", value: "tool_mobile_get_public_config")]
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"[{"index":0,"methodname":"tool_mobile_get_public_config","args":{}}]"#.utf8)
        let (data, _) = try await session.data(for: req)
        guard let profile = MoodleSiteProfile(publicConfig: data, site: site) else {
            throw MoodleError(message: "No Moodle site answered at this address.")
        }
        return profile
    }

    /// The page the official Moodle app opens for single sign-on (Microsoft 365, Google, SAML…). Once the school's
    /// sign-in finishes, Moodle redirects to `moodlemobile://token=<base64>`, which `token(fromLaunchReply:)` reads.
    public static func launchURL(site: URL, passport: String) -> URL {
        var comps = URLComponents(url: site.appendingPathComponent("admin/tool/mobile/launch.php"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "service", value: "moodle_mobile_app"),
                            URLQueryItem(name: "passport", value: passport),
                            URLQueryItem(name: "urlscheme", value: "moodlemobile")]
        return comps.url!
    }

    /// Whether a page is part of signing in: another host (Microsoft…), or Moodle's login, auth plugin, MFA or launch
    /// pages. Any other page on the site is where Moodle sends you once sign-in has finished.
    public static func isSignInPage(_ url: URL, site: URL) -> Bool {
        guard url.host?.lowercased() == site.host?.lowercased() else { return true }
        var path = url.path
        if !site.path.isEmpty, path.hasPrefix(site.path) { path = String(path.dropFirst(site.path.count)) }
        return ["/login", "/auth", "/admin/tool/mfa", "/admin/tool/mobile/launch.php"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Reads the web service token from the launch reply. Its payload is base64 of `signature:::token[:::privatetoken]`.
    /// The scheme isn't checked: a school with a branded app can force its own scheme in place of `moodlemobile`.
    public static func token(fromLaunchReply url: URL) throws -> String {
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard let start = text.range(of: "token=") else { throw MoodleError(message: "Moodle's sign-in reply had no token.") }
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        var b64 = String(text[start.upperBound...].unicodeScalars.prefix { alphabet.contains($0) })
        b64 = b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let payload = String(data: data, encoding: .utf8) else {
            throw MoodleError(message: "Moodle's sign-in reply could not be read.")
        }
        let parts = payload.components(separatedBy: ":::")
        guard parts.count >= 2, !parts[1].isEmpty, parts[1].allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw MoodleError(message: "Moodle's sign-in reply had no token.")
        }
        return parts[1]
    }

    static func form(_ params: [String: Any]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        var parts: [String] = []
        func add(_ key: String, _ value: Any) {
            switch value {
            case let arr as [Any]: for (i, v) in arr.enumerated() { add("\(key)[\(i)]", v) }
            case let dict as [String: Any]: for (k, v) in dict { add("\(key)[\(k)]", v) }
            default: parts.append("\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\("\(value)".addingPercentEncoding(withAllowedCharacters: allowed) ?? "")")
            }
        }
        for (k, v) in params.sorted(by: { $0.key < $1.key }) { add(k, v) }
        return parts.joined(separator: "&")
    }

    public func call(_ function: String, _ params: [String: Any] = [:]) async throws -> Any {
        var req = URLRequest(url: site.appendingPathComponent("webservice/rest/server.php"), timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = params
        all["wstoken"] = token
        all["wsfunction"] = function
        all["moodlewsrestformat"] = "json"
        req.httpBody = Self.form(all).data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MoodleError(message: "Moodle answered \(http.statusCode) for \(function).")
        }
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let d = obj as? [String: Any], d["exception"] != nil {
            let code = d["errorcode"] as? String ?? ""
            if code == "invalidtoken" { throw MoodleError(message: "The Moodle token is no longer valid. Sign in again in Settings.", code: code) }
            throw MoodleError(message: (d["message"] as? String ?? "Moodle error") + " (\(function))")
        }
        return obj
    }

    public func download(_ fileURL: String) async throws -> Data {
        guard var comps = URLComponents(string: fileURL) else { throw MoodleError(message: "Bad file address.") }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "token", value: token))
        comps.queryItems = items
        guard let url = comps.url else { throw MoodleError(message: "Bad file address.") }
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw MoodleError(message: "Download failed (\(http.statusCode)).") }
        return data
    }
}

/// A site's name, logo and sign-in button, from `tool_mobile_get_public_config`.
public struct MoodleSiteProfile: Equatable {
    /// The site's own address (wwwroot), which may differ from what was typed.
    public var site: URL
    public var name: String
    public var logoURL: URL?
    /// The school's single sign-on button (e.g. "Microsoft Office 365") when there is exactly one.
    public var providerName: String?
    /// Where that button leads. Only kept when it is on the site itself.
    public var providerURL: URL?
    /// Whether the school lets the Moodle app (and so Study Tracker) connect at all.
    public var appAccess: Bool

    public init?(publicConfig data: Data, site: URL) {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = arr.first,
              (first["error"] as? Bool) != true, let d = first["data"] as? [String: Any] else { return nil }
        func url(_ key: String) -> URL? { (d[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        func on(_ key: String) -> Bool { (d[key] as? NSNumber)?.boolValue ?? true }
        let root = url("httpswwwroot") ?? url("wwwroot") ?? site
        let providers = d["identityproviders"] as? [[String: Any]] ?? []
        let only = providers.count == 1 ? providers[0] : nil
        self.site = root
        name = MoodleSync.stripHTML(d["sitename"] as? String) ?? root.host ?? "Moodle"
        logoURL = url("compactlogourl") ?? url("logourl")
        providerName = only?["name"] as? String
        providerURL = (only?["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.host?.lowercased() == root.host?.lowercased() ? $0 : nil }
        appAccess = on("enablewebservices") && on("enablemobilewebservice")
    }
}

/// What the connection has brought in so far.
public struct MoodleStats: Equatable {
    public var courses = 0
    public var deadlines = 0
    public var grades = 0
    public var files = 0
}

public struct MoodleCourseInfo: Hashable {
    public var id: Int; public var shortname: String; public var fullname: String
    /// Course dates from Moodle, when the school sets them.
    public var start: Date?; public var end: Date?
    public init(id: Int, shortname: String, fullname: String, start: Date? = nil, end: Date? = nil) {
        self.id = id; self.shortname = shortname; self.fullname = fullname; self.start = start; self.end = end
    }

    init?(json d: [String: Any]) {
        guard let id = (d["id"] as? NSNumber)?.intValue else { return nil }
        func date(_ k: String) -> Date? { ((d[k] as? NSNumber)?.doubleValue).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }
        self.init(id: id, shortname: d["shortname"] as? String ?? "", fullname: d["fullname"] as? String ?? "",
                  start: date("startdate"), end: date("enddate"))
    }

    var json: [String: Any] {
        ["id": id, "shortname": shortname, "fullname": fullname,
         "startdate": start.map { Int($0.timeIntervalSince1970) } ?? 0, "enddate": end.map { Int($0.timeIntervalSince1970) } ?? 0]
    }
}

public struct MoodleSyncReport {
    public var courses: [MoodleCourseInfo] = []
    public var linked = 0
    public var assignmentsCreated = 0
    public var assignmentsUpdated = 0
    public var gradesUpdated = 0
    public var filesImported = 0
    public var conflicts = 0
    public var errors: [String] = []
    public var summary: String {
        var parts: [String] = []
        if assignmentsCreated > 0 { parts.append("\(assignmentsCreated) new deadline\(assignmentsCreated == 1 ? "" : "s")") }
        if assignmentsUpdated > 0 { parts.append("\(assignmentsUpdated) updated") }
        if gradesUpdated > 0 { parts.append("\(gradesUpdated) grade\(gradesUpdated == 1 ? "" : "s")") }
        if filesImported > 0 { parts.append("\(filesImported) new file\(filesImported == 1 ? "" : "s")") }
        if conflicts > 0 { parts.append("\(conflicts) conflict\(conflicts == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append("Everything is up to date") }
        if !errors.isEmpty { parts.append("\(errors.count) problem\(errors.count == 1 ? "" : "s")") }
        return parts.joined(separator: ", ") + "."
    }
}

public enum MoodleSync {
    public static let tokenAccount = "moodle-token"

    /// The courses Moodle listed at the last sync.
    public static func storedCourses(store: StudyStore) -> [MoodleCourseInfo] {
        (JSON.parse(store.setting("moodle_courses")) as? [[String: Any]] ?? []).compactMap(MoodleCourseInfo.init(json:))
    }

    /// Moodle courses running now (or starting within 60 days) that have no local course yet.
    public static func unlinkedCurrentCourses(store: StudyStore, now: Date = Date()) -> [MoodleCourseInfo] {
        let linked = Set(store.courses(includeArchived: true).compactMap(\.moodleId))
        return storedCourses(store: store).filter { c in
            !linked.contains(c.id) && (c.end.map { $0 > now } ?? true) && (c.start.map { $0 < now.adding(days: 60) } ?? true)
        }
    }

    /// First-run setup: creates the current term (from the courses' dates, unless one exists) and a local course for
    /// each current Moodle course, linked by Moodle id so the next sync brings in deadlines, grades and files.
    @discardableResult
    public static func createCoursesAndTerm(store: StudyStore, now: Date = Date()) throws -> (termCreated: Bool, courses: Int) {
        let todo = unlinkedCurrentCourses(store: store, now: now)
        guard !todo.isEmpty else { return (false, 0) }
        let tz = store.timezone
        var created = false
        let termId: Int
        if let t = store.currentTerm() {
            termId = t.id
        } else {
            let start = todo.compactMap(\.start).min() ?? now
            let end = todo.compactMap(\.end).max() ?? start.adding(days: 120)
            let first = LocalDate(start, tz: tz)
            let season = first.month >= 8 ? "Fall" : first.month >= 6 ? "Summer" : "Spring"
            termId = try store.saveTerm(Term(name: "\(season) \(first.year)", startDate: first, endDate: LocalDate(end, tz: tz), isCurrent: true))
            created = true
        }
        for c in todo {
            let code = c.shortname.trimmingCharacters(in: .whitespaces)
            let name = c.fullname.trimmingCharacters(in: .whitespaces)
            _ = try store.saveCourse(Course(termId: termId, code: code.isEmpty ? nil : code, name: name.isEmpty ? code : name,
                                            color: store.nextCourseColor(), moodleId: c.id))
        }
        store.audit("moodle_create_courses", detail: "\(todo.count) courses")
        return (created, todo.count)
    }

    public static func stats(store: StudyStore) -> MoodleStats {
        func count(_ sql: String) -> Int { (try? store.db.scalarInt(sql)) ?? 0 }
        return MoodleStats(courses: count("SELECT count(*) FROM courses WHERE moodle_id IS NOT NULL AND archived = 0"),
                           deadlines: count("SELECT count(*) FROM assignments WHERE source = 'moodle' AND dismissed = 0"),
                           grades: count("SELECT count(*) FROM assignments WHERE source = 'moodle' AND dismissed = 0 AND status = 'graded'"),
                           files: count("SELECT count(*) FROM materials WHERE external_uid LIKE 'moodle:%'"))
    }

    static func stripHTML(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        let noTags = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let t = noTags.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(4000))
    }

    /// Pulls deadlines, submission status, grades and new course files for linked courses.
    public static func run(store: StudyStore, client: MoodleClient, downloadFiles: Bool, autoConfirm: Bool, now: Date = Date()) async -> MoodleSyncReport {
        var report = MoodleSyncReport()
        func finish() {
            store.setSetting("moodle_last_sync", ISO.instant(now))
            store.setSetting("moodle_last_status", report.summary)
            store.audit("moodle_sync", detail: report.summary)
        }
        do {
            guard let info = try await client.call("core_webservice_get_site_info") as? [String: Any], let userId = (info["userid"] as? NSNumber)?.intValue else {
                report.errors.append("Could not read your Moodle profile."); return report
            }
            // Who the connection belongs to, shown in Settings.
            store.setBool("moodle_needs_signin", false)
            store.setSetting("moodle_user_name", info["fullname"] as? String)
            if let name = stripHTML(info["sitename"] as? String) { store.setSetting("moodle_site_name", name) }
            let list = try await client.call("core_enrol_get_users_courses", ["userid": userId]) as? [[String: Any]] ?? []
            report.courses = list.compactMap(MoodleCourseInfo.init(json:))
            store.setSetting("moodle_courses", JSON.string(report.courses.map(\.json)))

            // Link Moodle courses to local ones by code or name.
            var local = store.courses()
            for mc in report.courses where !local.contains(where: { $0.moodleId == mc.id }) {
                let candidates = local.filter { $0.moodleId == nil }
                if let c = CourseMatcher.best(mc.shortname + " " + mc.fullname, courses: candidates, minimum: 60) {
                    var u = c; u.moodleId = mc.id
                    _ = try? store.saveCourse(u)
                    report.linked += 1
                }
            }
            local = store.courses()
            let linked = Dictionary(uniqueKeysWithValues: local.compactMap { c in c.moodleId.map { ($0, c) } })
            guard !linked.isEmpty else { finish(); return report }

            // Assignments.
            let ids = Array(linked.keys)
            let assignResp = try await client.call("mod_assign_get_assignments", ["courseids": ids]) as? [String: Any]
            var assignIdByInstance: [Int: Int] = [:]
            for c in assignResp?["courses"] as? [[String: Any]] ?? [] {
                guard let mcid = (c["id"] as? NSNumber)?.intValue, let course = linked[mcid] else { continue }
                for a in c["assignments"] as? [[String: Any]] ?? [] {
                    guard let aid = (a["id"] as? NSNumber)?.intValue else { continue }
                    let due = (a["duedate"] as? NSNumber)?.doubleValue ?? 0
                    let cmid = (a["cmid"] as? NSNumber)?.intValue
                    let url = cmid.map { client.site.appendingPathComponent("mod/assign/view.php").absoluteString + "?id=\($0)" }
                    let r = upsert(store: store, uid: "assign:\(aid)", courseId: course.id, title: a["name"] as? String ?? "Assignment",
                                   kind: CourseMatcher.guessKind(a["name"] as? String ?? ""), due: due > 0 ? Date(timeIntervalSince1970: due) : nil,
                                   description: stripHTML(a["intro"] as? String), url: url, autoConfirm: autoConfirm)
                    report.assignmentsCreated += r.created; report.assignmentsUpdated += r.updated; report.conflicts += r.conflict
                    if let id = r.id { assignIdByInstance[aid] = id }
                    // Submission status for upcoming open work.
                    if let id = r.id, let local = store.assignment(id), local.isOpen, due == 0 || Date(timeIntervalSince1970: due) > now.adding(days: -14) {
                        if let st = try? await client.call("mod_assign_get_submission_status", ["assignid": aid]) as? [String: Any],
                           let last = st["lastattempt"] as? [String: Any], let sub = last["submission"] as? [String: Any],
                           (sub["status"] as? String) == "submitted" {
                            var u = local
                            u.status = .submitted
                            u.submittedAt = ((sub["timemodified"] as? NSNumber)?.doubleValue).map { Date(timeIntervalSince1970: $0) } ?? now
                            _ = try? store.saveAssignment(u, markModified: false)
                            report.assignmentsUpdated += 1
                        }
                    }
                }
            }

            // Other actionable items (quizzes, workshops…).
            if let ev = try? await client.call("core_calendar_get_action_events_by_timesort",
                                               ["timesortfrom": Int(now.adding(days: -7).timeIntervalSince1970), "limitnum": 50]) as? [String: Any] {
                for e in ev["events"] as? [[String: Any]] ?? [] {
                    guard let module = e["modulename"] as? String, module != "assign",
                          let mcid = ((e["course"] as? [String: Any])?["id"] as? NSNumber)?.intValue, let course = linked[mcid],
                          let inst = (e["instance"] as? NSNumber)?.intValue else { continue }
                    let ts = (e["timesort"] as? NSNumber)?.doubleValue ?? 0
                    let name = (e["activityname"] as? String) ?? (e["name"] as? String ?? module)
                    let kind: AssignmentKind = module == "quiz" ? .quiz : CourseMatcher.guessKind(name)
                    let r = upsert(store: store, uid: "\(module):\(inst)", courseId: course.id, title: name, kind: kind,
                                   due: ts > 0 ? Date(timeIntervalSince1970: ts) : nil, description: nil, url: e["url"] as? String, autoConfirm: autoConfirm)
                    report.assignmentsCreated += r.created; report.assignmentsUpdated += r.updated; report.conflicts += r.conflict
                }
            }

            // Grades.
            for (mcid, course) in linked {
                guard let g = try? await client.call("gradereport_user_get_grade_items", ["courseid": mcid, "userid": userId]) as? [String: Any],
                      let ug = (g["usergrades"] as? [[String: Any]])?.first else { continue }
                for item in ug["gradeitems"] as? [[String: Any]] ?? [] {
                    guard let module = item["itemmodule"] as? String, let inst = (item["iteminstance"] as? NSNumber)?.intValue else { continue }
                    let uid = "\(module):\(inst)"
                    guard let row = try? store.db.first("SELECT * FROM assignments WHERE source = 'moodle' AND external_uid = ?", [uid]) else { continue }
                    var a = Assignment(row: row)
                    guard a.courseId == course.id else { continue }
                    var changed = false
                    if let raw = (item["graderaw"] as? NSNumber)?.doubleValue, let max = (item["grademax"] as? NSNumber)?.doubleValue, max > 0 {
                        if a.score != raw || a.maxScore != max || a.status != .graded {
                            a.score = raw; a.maxScore = max; a.status = .graded; changed = true
                        }
                    }
                    if a.weightPct == nil, let w = (item["weightraw"] as? NSNumber)?.doubleValue, w > 0 { a.weightPct = (w * 1000).rounded() / 10; changed = true }
                    if changed { _ = try? store.saveAssignment(a, markModified: false); report.gradesUpdated += 1 }
                }
            }

            // Course files → Inbox (already filed under the linked course).
            if downloadFiles {
                for (mcid, course) in linked {
                    guard let sections = try? await client.call("core_course_get_contents", ["courseid": mcid]) as? [[String: Any]] else { continue }
                    for s in sections {
                        for mod in s["modules"] as? [[String: Any]] ?? [] {
                            guard ["resource", "folder"].contains(mod["modname"] as? String ?? "") else { continue }
                            for f in mod["contents"] as? [[String: Any]] ?? [] {
                                guard (f["type"] as? String) == "file", let name = f["filename"] as? String, let furl = f["fileurl"] as? String else { continue }
                                let ext = (name as NSString).pathExtension.lowercased()
                                guard MaterialParser.supportedExtensions.contains(ext), ["pptx", "pdf", "docx", "md", "txt"].contains(ext) else { continue }
                                let size = (f["filesize"] as? NSNumber)?.intValue ?? 0
                                guard size < MaterialParser.maxBytes else { continue }
                                let modified = (f["timemodified"] as? NSNumber)?.intValue ?? 0
                                let stableUid = "moodle:\(mcid):" + StudyStore.sha256(Data((furl + "\(modified)").utf8)).prefix(16)
                                if (try? store.db.scalarInt("SELECT count(*) FROM materials WHERE external_uid = ?", [stableUid])) ?? 0 > 0 { continue }
                                do {
                                    let data = try await client.download(furl)
                                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
                                    try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
                                    try data.write(to: tmp)
                                    let outcome = store.importMaterial(from: tmp, courseId: course.id, externalUid: stableUid, removeOriginal: true)
                                    if case .imported = outcome { report.filesImported += 1 }
                                    if case .duplicate(let id, _) = outcome {
                                        _ = try? store.db.execute("UPDATE materials SET external_uid = COALESCE(external_uid, ?) WHERE id = ?", [stableUid, id])
                                    }
                                } catch {
                                    report.errors.append("\(name): \(error)")
                                }
                            }
                        }
                    }
                }
            }
            finish()
        } catch {
            report.errors.append("\(error)")
            if (error as? MoodleClient.MoodleError)?.code == "invalidtoken" { store.setBool("moodle_needs_signin", true) }
            store.setSetting("moodle_last_status", "Sync failed: \(error)")
        }
        return report
    }

    struct UpsertResult { var id: Int?; var created = 0; var updated = 0; var conflict = 0 }

    static func upsert(store: StudyStore, uid: String, courseId: Int, title: String, kind: AssignmentKind, due: Date?, description: String?,
                       url: String?, autoConfirm: Bool) -> UpsertResult {
        var r = UpsertResult()
        if let row = try? store.db.first("SELECT * FROM assignments WHERE source = 'moodle' AND external_uid = ?", [uid]) {
            var a = Assignment(row: row)
            r.id = a.id
            if a.dismissed { return r }
            let changed = a.title != title || a.dueAt != due
            guard changed else { return r }
            if a.userModified && a.dueAt != due {
                let open = (try? store.db.scalarInt("SELECT count(*) FROM conflicts WHERE entity = 'assignment' AND entity_id = ? AND resolved_at IS NULL", [a.id])) ?? 0
                if open == 0 {
                    _ = try? store.db.execute("INSERT INTO conflicts(entity, entity_id, source, summary, incoming_json) VALUES('assignment',?,?,?,?)",
                                              [a.id, "moodle", "\(a.title): Moodle now says \(due.map { ISO.instant($0, in: store.timezone) } ?? "no due date").",
                                               JSON.string(["title": title, "due_at": due.map { ISO.instant($0) } as Any])])
                    r.conflict = 1
                }
                return r
            }
            a.title = title; a.dueAt = due; a.url = url ?? a.url
            if a.description == nil { a.description = description }
            _ = try? store.saveAssignment(a, markModified: false)
            r.updated = 1
            return r
        }
        let a = Assignment(courseId: courseId, title: title, description: description, kind: kind, dueAt: due, confirmed: autoConfirm,
                           source: "moodle", externalUid: uid, url: url)
        r.id = try? store.saveAssignment(a, markModified: false)
        r.created = 1
        return r
    }
}
