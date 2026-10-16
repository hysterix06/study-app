import Foundation

/// Brings Moodle into the app: this term's courses, their deadlines (with whether they're submitted), and the text of
/// their files. Nothing is asked: courses are added on their own (orientation pages hidden), deadlines are taken as
/// Moodle has them, and what Moodle no longer lists goes. Running it twice in a row changes nothing.
public enum MoodleSync {
    public struct Report: Equatable, Sendable {
        public var coursesAdded = 0
        public var deadlinesAdded = 0
        public var deadlinesChanged = 0
        public var deadlinesRemoved = 0
        public var filesRead = 0
        /// Files listed but not read: exercises, exams and other material the book doesn't use, or too large.
        public var filesNoted = 0
        public var filesRemoved = 0
        public var errors: [String] = []
        public var needsSignIn = false

        public var changedAnything: Bool {
            coursesAdded + deadlinesAdded + deadlinesChanged + deadlinesRemoved + filesRead + filesNoted + filesRemoved > 0
        }

        public var summary: String {
            var parts: [String] = []
            if coursesAdded > 0 { parts.append("\(coursesAdded) course\(coursesAdded == 1 ? "" : "s") added") }
            let deadlines = deadlinesAdded + deadlinesChanged + deadlinesRemoved
            if deadlines > 0 { parts.append("\(deadlines) deadline\(deadlines == 1 ? "" : "s") updated") }
            if filesRead > 0 { parts.append("\(filesRead) file\(filesRead == 1 ? "" : "s") read") }
            if parts.isEmpty { parts.append("Up to date") }
            if !errors.isEmpty { parts.append("\(errors.count) problem\(errors.count == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        }
    }

    public static let fileExtensions: Set<String> = ["pdf", "pptx", "docx", "md", "txt"]
    /// The most text kept from one file: plenty for its outline and an excerpt.
    public static let maxFileText = 60_000
    /// Larger files are listed but not downloaded (some school servers are slow, and big files are rarely slides).
    public static let maxDownload = 30 * 1024 * 1024

    public static func run(store: BookStore, client: MoodleClient, now: Date = Date(), readFiles: Bool = true,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Report {
        var report = Report()
        do {
            progress("Checking Moodle…")
            guard let info = try await client.call("core_webservice_get_site_info") as? [String: Any],
                  let userId = (info["userid"] as? NSNumber)?.intValue else {
                report.errors.append("Moodle didn't say who you are.")
                return finish(store, report, now)
            }
            store.setSetting("moodle_user_name", info["fullname"] as? String)
            store.setSetting("moodle_site_name", MoodleClient.stripHTML(info["sitename"] as? String))

            // This term's courses.
            let listed = (try await client.call("core_enrol_get_users_courses", ["userid": userId]) as? [[String: Any]] ?? [])
                .compactMap(MoodleCourseInfo.init(json:))
            var current: [Int: Int] = [:] // Moodle id → course id
            for c in MoodleCourses.current(listed, now: now) {
                let (name, code) = MoodleCourses.names(shortname: c.shortname, fullname: c.fullname)
                let r = try store.upsertMoodleCourse(moodleId: c.id, name: name, code: code, start: c.start, end: c.end,
                                                     hidden: MoodleCourses.looksAdministrative(c.fullname))
                if r.created { report.coursesAdded += 1 }
                current[c.id] = r.id
            }
            guard !current.isEmpty else { return finish(store, report, now) }
            // Week 1 of the term: the newest start date among this term's courses (orientation pages are usually set
            // up fresh each term even where course pages are copied with last year's dates).
            let day = 86_400.0
            let starts = MoodleCourses.current(listed, now: now).compactMap(\.start)
                .filter { $0 > now.addingTimeInterval(-180 * day) && $0 < now.addingTimeInterval(30 * day) }
            store.setSetting("term_start", starts.max().map { ISO.instant($0) })

            try await syncDeadlines(store: store, client: client, courses: current, now: now, report: &report)

            if readFiles {
                let visible = current.filter { store.course($0.value)?.hidden == false }.sorted { $0.key < $1.key }
                await syncFiles(store: store, client: client, courses: visible.map { ($0.key, $0.value) }, now: now, report: &report, progress: progress)
            }
        } catch {
            if (error as? MoodleClient.MoodleError)?.code == "invalidtoken" { report.needsSignIn = true }
            report.errors.append("\(error)")
        }
        return finish(store, report, now)
    }

    static func finish(_ store: BookStore, _ report: Report, _ now: Date) -> Report {
        store.setSetting("moodle_last_sync", ISO.instant(now))
        store.setSetting("moodle_last_status", report.errors.isEmpty ? report.summary : "Last sync had problems: \(report.errors[0])")
        store.setSetting("moodle_needs_signin", report.needsSignIn ? "1" : nil)
        return report
    }

    // MARK: Deadlines

    static func syncDeadlines(store: BookStore, client: MoodleClient, courses: [Int: Int], now: Date, report: inout Report) async throws {
        var seen = Set<String>()
        let day = 86_400.0

        // Assignments, and whether each recent one is submitted.
        let resp = try await client.call("mod_assign_get_assignments", ["courseids": courses.keys.sorted()]) as? [String: Any]
        for c in resp?["courses"] as? [[String: Any]] ?? [] {
            guard let mid = (c["id"] as? NSNumber)?.intValue, let courseId = courses[mid] else { continue }
            for a in c["assignments"] as? [[String: Any]] ?? [] {
                guard let aid = (a["id"] as? NSNumber)?.intValue else { continue }
                let uid = "assign:\(aid)"
                seen.insert(uid)
                let dueRaw = (a["duedate"] as? NSNumber)?.doubleValue ?? 0
                let due = dueRaw > 0 ? Date(timeIntervalSince1970: dueRaw) : nil
                let url = (a["cmid"] as? NSNumber).map { client.site.appendingPathComponent("mod/assign/view.php").absoluteString + "?id=\($0.intValue)" }
                var submitted = (try? store.db.first("SELECT submitted FROM deadlines WHERE moodle_uid = ?", [uid]))??.bool("submitted") ?? false
                if let due, due > now.addingTimeInterval(-14 * day), due < now.addingTimeInterval(90 * day) {
                    if let st = try? await client.call("mod_assign_get_submission_status", ["assignid": aid]) as? [String: Any] {
                        let status = ((st["lastattempt"] as? [String: Any])?["submission"] as? [String: Any])?["status"] as? String
                        submitted = status == "submitted"
                    }
                }
                let change = try store.upsertDeadline(courseId: courseId, uid: uid, title: MoodleClient.stripHTML(a["name"] as? String) ?? "Assignment",
                                                      kind: "assignment", due: due, url: url, submitted: submitted, now: now)
                count(change, &report)
            }
        }

        // Everything else Moodle shows as due (quizzes, forums, workshops).
        var otherSucceeded = false
        if let ev = try? await client.call("core_calendar_get_action_events_by_timesort",
                                           ["timesortfrom": Int(now.addingTimeInterval(-7 * day).timeIntervalSince1970), "limitnum": 50]) as? [String: Any] {
            otherSucceeded = true
            for e in ev["events"] as? [[String: Any]] ?? [] {
                guard let module = e["modulename"] as? String, module != "assign",
                      let mid = ((e["course"] as? [String: Any])?["id"] as? NSNumber)?.intValue, let courseId = courses[mid],
                      let instance = (e["instance"] as? NSNumber)?.intValue else { continue }
                let uid = "\(module):\(instance)"
                seen.insert(uid)
                let ts = (e["timesort"] as? NSNumber)?.doubleValue ?? 0
                let title = MoodleClient.stripHTML((e["activityname"] as? String) ?? (e["name"] as? String)) ?? module.capitalized
                let change = try store.upsertDeadline(courseId: courseId, uid: uid, title: title, kind: module,
                                                      due: ts > 0 ? Date(timeIntervalSince1970: ts) : nil, url: e["url"] as? String,
                                                      submitted: false, now: now)
                count(change, &report)
            }
        }
        if !otherSucceeded {
            // Keep what the failed call would have confirmed.
            for row in (try? store.db.query("SELECT moodle_uid FROM deadlines WHERE moodle_uid NOT LIKE 'assign:%'")) ?? [] { seen.insert(row.str("moodle_uid")) }
        }
        report.deadlinesRemoved += try store.removeDeadlines(courseIds: Array(courses.values), keeping: seen)
    }

    static func count(_ change: BookStore.Change, _ report: inout Report) {
        switch change {
        case .added: report.deadlinesAdded += 1
        case .changed: report.deadlinesChanged += 1
        case .same: break
        }
    }

    // MARK: Files

    struct Listed {
        var uid: String, name: String, section: String?, module: String?, position: Int, url: String, modified: Int, size: Int
    }

    /// A course's files in course order, from its Moodle page.
    static func list(_ client: MoodleClient, moodleId: Int) async throws -> [Listed] {
        guard let sections = try await client.call("core_course_get_contents", ["courseid": moodleId]) as? [[String: Any]] else { return [] }
        var listed: [Listed] = []
        for s in sections {
            let section = MoodleClient.stripHTML(s["name"] as? String)
            for mod in s["modules"] as? [[String: Any]] ?? [] {
                guard ["resource", "folder"].contains(mod["modname"] as? String ?? ""), let cmid = (mod["id"] as? NSNumber)?.intValue else { continue }
                let module = MoodleClient.stripHTML(mod["name"] as? String)
                for f in mod["contents"] as? [[String: Any]] ?? [] {
                    guard (f["type"] as? String) == "file", let name = f["filename"] as? String, let url = f["fileurl"] as? String,
                          fileExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                    let path = (f["filepath"] as? String) ?? "/"
                    listed.append(Listed(uid: "file:\(cmid):\(path)\(name)", name: name, section: section, module: module, position: listed.count,
                                         url: url, modified: (f["timemodified"] as? NSNumber)?.intValue ?? 0, size: (f["filesize"] as? NSNumber)?.intValue ?? 0))
                }
            }
        }
        return listed
    }

    /// Lists every course's files, then reads only what the book uses: every syllabus first, then lectures and
    /// readings, taking turns between courses so each one gets going early. Three downloads run at a time. Files read
    /// before and unchanged are skipped, so an interrupted first sync simply carries on next time.
    static func syncFiles(store: BookStore, client: MoodleClient, courses: [(moodleId: Int, courseId: Int)], now: Date, report: inout Report,
                          progress: @escaping @Sendable (String) -> Void) async {
        var syllabi: [(Listed, Int)] = []
        var lectures: [[(Listed, Int)]] = []
        var listedOK: [Int] = []
        for (moodleId, courseId) in courses {
            do {
                let listed = try await list(client, moodleId: moodleId)
                listedOK.append(courseId)
                report.filesRemoved += try store.removeFiles(courseId: courseId, keeping: Set(listed.map(\.uid)))
                var mine: [(Listed, Int)] = []
                for l in listed {
                    if let stamp = store.fileStamp(l.uid), stamp.modified == l.modified, stamp.size == l.size {
                        store.placeFile(l.uid, section: l.section, module: l.module, position: l.position)
                        continue
                    }
                    let guess = FileKind.classify(name: l.name, section: l.section, module: l.module)
                    if guess.kind == FileKind.other || l.size > maxDownload {
                        try store.upsertFile(courseId: courseId, uid: l.uid, name: l.name, section: l.section, module: l.module, position: l.position,
                                             kind: FileKind.other, week: guess.week, modified: l.modified, size: l.size, text: "", headings: [],
                                             error: l.size > maxDownload ? "Too large to read" : nil, now: now)
                        report.filesNoted += 1
                    } else {
                        // Listed now, read soon: a table of contents can already use its title.
                        if store.fileStamp(l.uid) == nil {
                            try store.upsertFile(courseId: courseId, uid: l.uid, name: l.name, section: l.section, module: l.module, position: l.position,
                                                 kind: guess.kind, week: guess.week, modified: -1, size: l.size, text: "", headings: [], error: nil, now: now)
                        }
                        if guess.kind == FileKind.syllabus { syllabi.append((l, courseId)) } else { mine.append((l, courseId)) }
                    }
                }
                lectures.append(mine)
            } catch {
                report.errors.append("\(store.course(courseId)?.name ?? "A course"): \(error)")
            }
        }
        // Every syllabus, then one lecture from each course in turn.
        var todo = syllabi
        var round = 0
        while lectures.contains(where: { round < $0.count }) {
            for l in lectures where round < l.count { todo.append(l[round]) }
            round += 1
        }
        if !todo.isEmpty {
            var done = 0
            let total = todo.count
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < todo.count else { return }
                    let (item, courseId) = todo[next]
                    next += 1
                    group.addTask { try? await read(item, store: store, client: client, courseId: courseId, now: now) }
                }
                for _ in 0..<3 { add() }
                while await group.next() != nil {
                    done += 1
                    progress("Reading course files: \(done) of \(total)")
                    add()
                }
            }
            report.filesRead += total
        }
        for courseId in listedOK { store.markFilesSynced(courseId, now: now) }
    }

    /// Downloads one file, keeps its text and headings, and throws the file itself away.
    static func read(_ l: Listed, store: BookStore, client: MoodleClient, courseId: Int, now: Date) async throws {
        var text = "", headings: [String] = [], problem: String?
        do {
            let data = try await client.download(l.url)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-file-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent(l.name)
            try data.write(to: file)
            let parsed = try MaterialParser.parse(file, options: .init(assetsDir: nil, ocrScannedPages: true, renderPDFPages: false))
            (text, headings) = condensed(parsed.chunks)
        } catch {
            problem = "\(error)"
        }
        let (kind, week) = FileKind.classify(name: l.name, section: l.section, module: l.module, text: text)
        try store.upsertFile(courseId: courseId, uid: l.uid, name: l.name, section: l.section, module: l.module, position: l.position,
                             kind: kind, week: week, modified: l.modified, size: l.size, text: text, headings: headings, error: problem, now: now)
    }

    /// A file's slides or pages as one text, headers, footers and filler slides removed, with its distinct headings.
    public static func condensed(_ chunks: [ParsedChunk]) -> (text: String, headings: [String]) {
        let kept = MaterialCondenser.condense(chunks).chunks
        var headings: [String] = []
        for h in kept.compactMap(\.heading) where !h.isEmpty && !headings.contains(h) && headings.count < 16 { headings.append(h) }
        var text = kept.map { c in [c.heading.map { "## \($0)" }, c.textMd.isEmpty ? nil : c.textMd].compactMap { $0 }.joined(separator: "\n") }
            .joined(separator: "\n\n")
        if text.count > maxFileText { text = String(text.prefix(maxFileText)) }
        return (text, headings)
    }
}
