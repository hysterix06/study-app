import Foundation

/// Portability (§10): everything the student owns can leave the app in open formats.
public enum Exporter {
    static let tables = ["settings", "terms", "term_breaks", "courses", "class_patterns", "class_exceptions", "calendar_sources", "events",
                         "materials", "chunks", "assignments", "concepts", "concept_sources", "concept_links", "questions", "cards",
                         "card_reviews", "notes", "handwriting_captures", "study_sessions", "study_blocks", "conflicts", "audit_log"]

    /// One JSON file with every table, plus a Markdown folder of concepts, notes and sheets.
    @discardableResult
    public static func fullExport(store: StudyStore, to folder: URL? = nil) throws -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HHmm"
        let root = folder ?? store.paths.export.appendingPathComponent("StudyTracker-export-\(f.string(from: Date()))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var dump: [String: Any] = ["exported_at": ISO.instant(Date()), "schema_version": Migrations.currentVersion]
        for t in tables {
            let rows = try store.db.query("SELECT * FROM \(t)")
            dump[t] = rows.map { r in r.dictionary.mapValues { $0.jsonValue } }
        }
        try JSON.string(dump, pretty: true).write(to: root.appendingPathComponent("study-tracker.json"), atomically: true, encoding: .utf8)
        try markdownExport(store: store, to: root.appendingPathComponent("Markdown"), obsidian: false)
        try ankiExport(store: store, to: root.appendingPathComponent("cards-anki.tsv"))
        store.audit("export_full", detail: root.path)
        return root
    }

    /// Writes one folder per course. With `obsidian`, files carry YAML frontmatter and wiki links between concepts.
    public static func markdownExport(store: StudyStore, to root: URL, obsidian: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for c in store.courses(includeArchived: true) {
            let dir = root.appendingPathComponent(Slug.make(c.codeOrName))
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let concepts = store.concepts(courseId: c.id)
            let byId = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0) })
            let links = store.conceptLinks(courseId: c.id)
            var index = "# \(c.name)\n\n"
            if !concepts.isEmpty {
                let conceptDir = dir.appendingPathComponent("Concepts")
                try fm.createDirectory(at: conceptDir, withIntermediateDirectories: true)
                index += "## Concepts\n\n"
                for k in concepts {
                    var md = obsidian ? "---\ncourse: \"\(c.codeOrName)\"\ntype: concept\nimportance: \(k.importance)\ncreated_by: \(k.createdBy)\n---\n\n" : ""
                    md += "# \(k.name)\n\n\(k.definition)\n\n"
                    let src = store.conceptSources(k.id)
                    if !src.isEmpty { md += "**Sources:** " + src.map { "\($0.materialTitle), \($0.locator)" }.joined(separator: "; ") + "\n\n" }
                    let out = links.filter { $0.from == k.id }.compactMap { l in byId[l.to].map { (l.relation, $0.name) } }
                    if !out.isEmpty {
                        md += "## Links\n\n" + out.map { "- \($0.0.replacingOccurrences(of: "_", with: " ")): " + (obsidian ? "[[\($0.1)]]" : $0.1) }.joined(separator: "\n") + "\n"
                    }
                    try md.write(to: conceptDir.appendingPathComponent(Slug.make(k.name) + ".md"), atomically: true, encoding: .utf8)
                    index += "- " + (obsidian ? "[[\(k.name)]]" : k.name) + "\n"
                }
            }
            let notes = store.notes(courseId: c.id)
            if !notes.isEmpty {
                let notesDir = dir.appendingPathComponent("Notes")
                try fm.createDirectory(at: notesDir, withIntermediateDirectories: true)
                index += "\n## Notes and sheets\n\n"
                for n in notes {
                    let material = n.materialId.flatMap { store.material($0) }?.title ?? ""
                    var md: String
                    if n.kind == "cornell_sheet", let sheet = CornellSheet.decode(n.dataJson) {
                        md = obsidian ? sheet.obsidianMarkdown : sheet.markdown
                    } else {
                        md = obsidian ? "---\ncourse: \"\(c.codeOrName)\"\nmaterial: \"\(material.replacingOccurrences(of: "\"", with: "'"))\"\ntype: \(n.kind)\ncreated_by: \(n.createdBy)\n---\n\n" : ""
                        md += "# \(n.title)\n\n\(n.contentMd)\n"
                    }
                    let name = Slug.make("\(n.kind.replacingOccurrences(of: "_", with: " ")) - \(n.title)")
                    try md.write(to: notesDir.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
                    index += "- " + (obsidian ? "[[\(name)]]" : n.title) + "\n"
                }
            }
            try index.write(to: dir.appendingPathComponent("\(Slug.make(c.codeOrName)).md"), atomically: true, encoding: .utf8)
        }
    }

    /// Tab-separated front/back/tags that Anki imports directly (File → Import), so reviews can happen on a phone.
    public static func ankiExport(store: StudyStore, to url: URL) throws {
        let courses = store.courseMap()
        var out = "#separator:tab\n#html:false\n#tags column:3\n"
        for card in store.cards(status: "active") {
            func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            let tag = Slug.make(courses[card.courseId]?.codeOrName ?? "study").replacingOccurrences(of: " ", with: "_")
            let back = card.back + (card.sourceLocators.map { " (\($0))" } ?? "")
            out += "\(clean(card.front))\t\(clean(back))\tStudyTracker \(tag)\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// An .ics of classes, deadlines and planned study, for any calendar app that can import or subscribe to a file.
    public static func icsFeed(store: StudyStore, days: Int = 120, now: Date = Date()) -> String {
        let tz = store.timezone
        let today = LocalDate(now, tz: tz)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Study Tracker//EN", "CALSCALE:GREGORIAN", "X-WR-CALNAME:Study Tracker"]
        let stamp = ICS.utcStamp(now)
        for o in store.occurrences(from: today.adding(days: -7), to: today.adding(days: days), includeBusy: false) where o.status != .canceled {
            lines += ["BEGIN:VEVENT", "UID:\(o.key)@studytracker", "DTSTAMP:\(stamp)", "DTSTART:\(ICS.utcStamp(o.start))", "DTEND:\(ICS.utcStamp(o.end))",
                      "SUMMARY:\(ICS.escape(o.title))"]
            if let l = o.location { lines.append("LOCATION:\(ICS.escape(l))") }
            lines.append("END:VEVENT")
        }
        let courses = store.courseMap()
        for a in store.assignments() where a.dueAt != nil && a.isOpen {
            let c = a.courseId.flatMap { courses[$0]?.displayName }.map { "[\($0)] " } ?? ""
            lines += ["BEGIN:VEVENT", "UID:a\(a.id)@studytracker", "DTSTAMP:\(stamp)", "DTSTART:\(ICS.utcStamp(a.dueAt!.adding(minutes: -15)))",
                      "DTEND:\(ICS.utcStamp(a.dueAt!))", "SUMMARY:\(ICS.escape("Due: \(c)\(a.title)"))", "END:VEVENT"]
        }
        for b in store.studyBlocks(from: now.adding(days: -1), to: now.adding(days: Double(days)), statuses: ["planned"]) {
            lines += ["BEGIN:VEVENT", "UID:b\(b.id)@studytracker", "DTSTAMP:\(stamp)", "DTSTART:\(ICS.utcStamp(b.plannedStart))",
                      "DTEND:\(ICS.utcStamp(b.end))", "SUMMARY:\(ICS.escape("Study: \(b.focus ?? "")"))", "END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
