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
        public init(message: String) { self.message = message }
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
        throw MoodleError(message: msg + " If your school uses single sign-on, paste a token from Moodle → Preferences → Security keys instead.")
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
            if code == "invalidtoken" { throw MoodleError(message: "The Moodle token is no longer valid. Sign in again in Settings.") }
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

public struct MoodleCourseInfo: Hashable {
    public var id: Int; public var shortname: String; public var fullname: String
    public init(id: Int, shortname: String, fullname: String) { self.id = id; self.shortname = shortname; self.fullname = fullname }
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
        do {
            guard let info = try await client.call("core_webservice_get_site_info") as? [String: Any], let userId = (info["userid"] as? NSNumber)?.intValue else {
                report.errors.append("Could not read your Moodle profile."); return report
            }
            let list = try await client.call("core_enrol_get_users_courses", ["userid": userId]) as? [[String: Any]] ?? []
            report.courses = list.compactMap { c in
                guard let id = (c["id"] as? NSNumber)?.intValue else { return nil }
                return MoodleCourseInfo(id: id, shortname: c["shortname"] as? String ?? "", fullname: c["fullname"] as? String ?? "")
            }
            store.setSetting("moodle_courses", JSON.string(report.courses.map { ["id": $0.id, "shortname": $0.shortname, "fullname": $0.fullname] }))

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
            guard !linked.isEmpty else { return report }

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
            store.setSetting("moodle_last_sync", ISO.instant(now))
            store.setSetting("moodle_last_status", report.summary)
            store.audit("moodle_sync", detail: report.summary)
        } catch {
            report.errors.append("\(error)")
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
