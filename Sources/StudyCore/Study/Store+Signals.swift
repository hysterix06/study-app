import Foundation

public extension StudyStore {
    /// Everything the course builder needs to lay out a course, compactly: its syllabus, what each lecture covers (with
    /// chunk ids to cite), its practice and past exams, its deadlines, the current path (so topic ids carry over) and
    /// what the student set aside. `budget` caps the characters of lecture outlines and syllabus text (large for Claude,
    /// small for free models).
    func courseSignals(courseId: Int, budget: Int = 60_000, now: Date = Date()) -> [String: Any] {
        guard let course = course(courseId) else { return [:] }
        let term = terms().first { $0.id == course.termId }
        let files = materials(courseId: courseId)
        var out: [String: Any] = [
            "course": ["id": course.id, "code": course.code as Any, "name": course.name, "short_name": course.shortName as Any,
                       "instructor": course.instructor as Any, "term": term?.name as Any,
                       "term_dates": term.map { ["start": $0.startDate.string, "end": $0.endDate.string] } as Any],
            "today": LocalDate(now, tz: timezone).string,
        ]
        var used = 0

        // Syllabi: what free AI read from them, else their opening text.
        out["syllabus"] = files.filter { $0.group == .info }.prefix(4).map { m -> [String: Any] in
            var d: [String: Any] = ["material_id": m.id, "title": m.title, "role": m.role.rawValue]
            if let scan = materialScan(materialId: m.id, kind: "syllabus").flatMap({ JSON.parse($0) as? [String: Any] }) {
                d["read"] = scan
            } else {
                let text = chunks(materialId: m.id).map { $0.textMd }.joined(separator: "\n")
                let n = min(6_000, max(0, budget / 6 - used))
                d["text"] = String(text.prefix(n))
                used += min(n, text.count)
            }
            return d
        }

        // Lectures, readings and class examples: an outline of each, in teaching order, with chunk ids to cite.
        let teaching = files.filter { $0.group == .path || $0.role == .example && !$0.excluded && $0.status == "ready" }
            .sorted { ($0.taughtOn?.string ?? "9999", $0.importedAt, $0.id) < ($1.taughtOn?.string ?? "9999", $1.importedAt, $1.id) }
        let perFile = max(400, min(4_000, (budget - used) / max(1, teaching.count)))
        out["lectures"] = teaching.map { m -> [String: Any] in
            var lines: [String] = []
            var size = 0
            for c in chunks(materialId: m.id) {
                let first = c.textMd.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-# \t")) }
                    .first { !$0.isEmpty && $0 != c.heading } ?? ""
                var line = "[\(c.id)] \(c.locator)"
                if let h = c.heading?.nilIfEmpty { line += " · \(h)" }
                if !first.isEmpty { line += " — \(first.prefix(110))" }
                if Self.emphasisCue(c.textMd + " " + (c.notesMd ?? "")) { line += " ⚑" }
                guard size + line.count <= perFile else { lines.append("…"); break }
                lines.append(line)
                size += line.count
            }
            used += size
            var d: [String: Any] = ["material_id": m.id, "title": m.title, "role": m.role.rawValue, "outline": lines]
            if let t = m.taughtOn { d["taught_on"] = t.string }
            if let s = m.sectionName { d["moodle_section"] = s }
            return d
        }

        // Practice and past exams: what they practise, and marks per topic.
        let items = practiceItems(courseId: courseId).filter { $0.source == "course" }
        let byFile = Dictionary(grouping: items, by: { $0.materialId ?? 0 })
        out["practice"] = files.filter { $0.group == .practice }.map { m -> [String: Any] in
            let mine = byFile[m.id] ?? []
            return ["material_id": m.id, "title": m.title, "role": m.role.rawValue, "problems": mine.count,
                    "with_solutions": mine.filter { $0.solutionMd != nil }.count,
                    "topics": Array(Set(mine.compactMap(\.topicLabel))).sorted().prefix(20).map { $0 }]
        }
        out["past_exams"] = files.filter { $0.group == .exams }.map { m -> [String: Any] in
            let mine = byFile[m.id] ?? []
            var marks: [String: Double] = [:]
            for i in mine { marks[i.topicLabel ?? "unlabelled", default: 0] += i.marks ?? 0 }
            return ["material_id": m.id, "title": m.title, "questions": mine.count, "marks_by_topic": marks,
                    "kinds": Array(Set(mine.map(\.kind).filter { $0 != "other" })).sorted()]
        }

        // Deadlines, with the topics already mapped to each.
        out["deadlines"] = assignments(AssignmentFilter(courseId: courseId)).map { a -> [String: Any] in
            var d: [String: Any] = ["assignment_id": a.id, "title": a.title, "kind": a.kind.rawValue]
            if let due = a.dueAt { d["due"] = ISO.instant(due, in: timezone) }
            if let w = a.weightPct { d["weight_pct"] = w }
            let mapped = assessmentTopicIds(assignmentId: a.id)
            if !mapped.isEmpty { d["topic_ids"] = mapped }
            return d
        }

        // The current path: keep a topic's id when it stays, so the student's progress stays with it.
        if let p = path(courseId: courseId) {
            let numbers = topicNumbers(courseId: courseId)
            let topics = self.topics(courseId: courseId)
            out["current_path"] = ["tier": p.tier, "version": p.version, "units": units(courseId: courseId).map { u -> [String: Any] in
                ["title": u.title, "topics": topics.filter { $0.unitId == u.id }.map { t -> [String: Any] in
                    var d: [String: Any] = ["id": t.id, "key": t.key, "title": t.title, "number": numbers[t.id] ?? ""]
                    if t.mastery != .new { d["mastery"] = t.mastery.rawValue }
                    if t.inNotebook { d["in_notebook"] = true }
                    if t.isSkipped { d["student_skipped"] = t.userState }
                    return d
                }]
            }]
        }
        let concepts = self.concepts(courseId: courseId).prefix(60).map(\.name)
        if !concepts.isEmpty { out["earlier_concepts"] = Array(concepts) }
        let setAside = files.filter { $0.group == .notUsed }.map(\.title)
        if !setAside.isEmpty { out["not_used"] = setAside }
        return out
    }

    /// "This will be on the exam", "important!", "remember": a lecturer stressing something.
    static func emphasisCue(_ s: String) -> Bool {
        let t = s.lowercased()
        return ["exam", "important", "remember", "key point", "must know", "prüfung", "examen", "esame", "tentamen", "wichtig", "importante", "!!"]
            .contains { t.contains($0) }
    }
}
