import Foundation

/// Write operations Claude may perform through MCP. Everything here is an insert of a proposal or an upsert
/// of a Claude-owned row (§8.4); nothing edits or deletes the student's data.
public extension StudyStore {
    struct AssignmentProposal {
        public var courseId: Int; public var title: String; public var kind: String?; public var dueAt: String?
        public var weightPct: Double?; public var estHours: Double?; public var description: String?
        public var sourceMaterialId: Int?; public var sourceLocator: String?; public var minPassPct: Double?; public var groupMembers: String?
        public init(courseId: Int, title: String, kind: String? = nil, dueAt: String? = nil, weightPct: Double? = nil, estHours: Double? = nil,
                    description: String? = nil, sourceMaterialId: Int? = nil, sourceLocator: String? = nil, minPassPct: Double? = nil, groupMembers: String? = nil) {
            self.courseId = courseId; self.title = title; self.kind = kind; self.dueAt = dueAt; self.weightPct = weightPct; self.estHours = estHours
            self.description = description; self.sourceMaterialId = sourceMaterialId; self.sourceLocator = sourceLocator
            self.minPassPct = minPassPct; self.groupMembers = groupMembers
        }
    }

    func proposeAssignments(_ items: [AssignmentProposal]) throws -> WriteResult {
        if items.count > 30 { throw ToolError("TOO_LARGE", "At most 30 items per call (got \(items.count)).", hint: "Split into several calls.") }
        var parsed: [(AssignmentProposal, Date?, AssignmentKind)] = []
        for p in items {
            guard course(p.courseId) != nil else { throw ToolError.notFound("Course \(p.courseId) does not exist.", hint: "Call list_courses for valid ids.") }
            guard !p.title.isEmpty, p.title.count <= 200 else { throw ToolError.invalid("title must be 1-200 characters.") }
            var due: Date?
            if let s = p.dueAt {
                let hasOffset = s.hasSuffix("Z") || s.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
                guard hasOffset, let d = ISO.parse(s) else {
                    throw ToolError.invalid("due_at \"\(s)\" must be ISO 8601 with an offset, e.g. 2026-10-06T23:59:00+02:00.",
                                            hint: "If the time or year is unclear in the source, omit due_at instead of guessing.")
                }
                due = d
            }
            if let w = p.weightPct, !(0...100).contains(w) { throw ToolError.invalid("weight_pct must be between 0 and 100.") }
            if let h = p.estHours, !(0...200).contains(h) { throw ToolError.invalid("est_hours must be between 0 and 200.") }
            if let m = p.minPassPct, !(0...100).contains(m) { throw ToolError.invalid("min_pass_pct must be between 0 and 100.") }
            if let mid = p.sourceMaterialId, material(mid) == nil { throw ToolError.reference("Material \(mid) does not exist.") }
            let kind = p.kind.flatMap { AssignmentKind(rawValue: $0) } ?? CourseMatcher.guessKind(p.title)
            if let k = p.kind, AssignmentKind(rawValue: k) == nil {
                throw ToolError.invalid("kind must be one of " + AssignmentKind.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            parsed.append((p, due, kind))
        }
        var r = WriteResult()
        let tz = timezone
        try db.transaction {
            for (p, due, kind) in parsed {
                let dupRows = try db.query("SELECT due_at FROM assignments WHERE course_id = ? AND lower(title) = lower(?)", [p.courseId, p.title])
                let isDup = dupRows.contains { row in
                    let other = row.string("due_at").flatMap { ISO.parse($0) }
                    switch (other, due) {
                    case (nil, nil): return true
                    case (let a?, let b?): return LocalDate(a, tz: tz) == LocalDate(b, tz: tz)
                    default: return false
                    }
                }
                if isDup { r.skipped.append((p.title, "Already exists for this course with the same due date.")); continue }
                let a = Assignment(courseId: p.courseId, title: p.title, description: p.description, kind: kind, dueAt: due,
                                   weightPct: p.weightPct, estHours: p.estHours, minPassPct: p.minPassPct, groupMembers: p.groupMembers,
                                   confirmed: false, source: "claude", sourceMaterialId: p.sourceMaterialId, sourceLocator: p.sourceLocator)
                let id = try saveAssignment(a, markModified: false)
                r.ids.append(id); r.created += 1
            }
            audit("propose_assignments", detail: ["created": r.created])
        }
        return r
    }

    struct BlockProposal {
        public var courseId: Int?; public var assignmentId: Int?; public var plannedStart: String; public var plannedMinutes: Int; public var focus: String?
        public init(courseId: Int? = nil, assignmentId: Int? = nil, plannedStart: String, plannedMinutes: Int, focus: String? = nil) {
            self.courseId = courseId; self.assignmentId = assignmentId; self.plannedStart = plannedStart; self.plannedMinutes = plannedMinutes; self.focus = focus
        }
    }

    func proposeStudyBlocks(_ items: [BlockProposal], now: Date = Date()) throws -> WriteResult {
        if items.count > 40 { throw ToolError("TOO_LARGE", "At most 40 blocks per call.") }
        var parsed: [(BlockProposal, Date)] = []
        for b in items {
            guard (10...180).contains(b.plannedMinutes) else { throw ToolError.invalid("planned_minutes must be between 10 and 180.") }
            guard let start = ISO.parse(b.plannedStart, tz: timezone) else { throw ToolError.invalid("planned_start \"\(b.plannedStart)\" is not an ISO 8601 date-time.") }
            if let c = b.courseId, course(c) == nil { throw ToolError.notFound("Course \(c) does not exist.") }
            if let a = b.assignmentId, assignment(a) == nil { throw ToolError.notFound("Assignment \(a) does not exist.") }
            parsed.append((b, start))
        }
        var r = WriteResult()
        let lo = parsed.map(\.1).min() ?? now, hi = parsed.map(\.1).max() ?? now
        let busy = busyIntervals(from: lo.adding(days: -1), to: hi.adding(days: 1))
        let f = DateFormatter(); f.timeZone = timezone; f.dateFormat = "EEE d MMM HH:mm"
        try db.transaction {
            for (b, start) in parsed {
                let end = start.adding(minutes: b.plannedMinutes)
                if start < now { r.warnings.append("Block at \(f.string(from: start)) starts in the past.") }
                if busy.contains(where: { $0.start < end && $0.end > start }) { r.warnings.append("Block at \(f.string(from: start)) overlaps a class or busy time.") }
                let courseId = b.courseId ?? b.assignmentId.flatMap { assignment($0)?.courseId }
                let id = try saveStudyBlock(StudyBlock(courseId: courseId, assignmentId: b.assignmentId, plannedStart: start,
                                                       plannedMinutes: b.plannedMinutes, focus: b.focus, status: "proposed", createdBy: "claude"))
                r.ids.append(id); r.created += 1
            }
            audit("propose_study_blocks", detail: ["created": r.created])
        }
        return r
    }

    func markMaterialProcessedChecked(_ id: Int) throws {
        guard material(id) != nil else { throw ToolError.notFound("Material \(id) does not exist.") }
        let n = try db.scalarInt("SELECT count(*) FROM concept_sources WHERE material_id = ?", [id])
        guard n > 0 else {
            throw ToolError("PRECONDITION", "Material \(id) has no concepts yet.", hint: "Call save_concepts for this material first.")
        }
        try markProcessed(id)
        audit("mark_material_processed", entity: "material", id: id)
    }

    func saveNoteChecked(materialId: Int?, courseId: Int?, assignmentId: Int?, kind: String, title: String, content: String) throws -> WriteResult {
        let allowed = ["gap_report", "summary", "session_log", "handwriting_review", "rubric_check", "practice_set", "exam_patterns"]
        guard allowed.contains(kind) else {
            throw ToolError.invalid("kind must be one of \(allowed.joined(separator: ", ")).", hint: "Use save_cornell_sheet for sheets. user_note is for the student only.")
        }
        guard !title.isEmpty, title.count <= 160 else { throw ToolError.invalid("title must be 1-160 characters.") }
        guard !content.isEmpty, content.count <= 20000 else { throw ToolError("TOO_LARGE", "content_md must be 1-20000 characters.") }
        var course = courseId
        if let materialId {
            guard let m = material(materialId) else { throw ToolError.notFound("Material \(materialId) does not exist.") }
            course = course ?? m.courseId
        }
        if let assignmentId {
            guard let a = assignment(assignmentId) else { throw ToolError.notFound("Assignment \(assignmentId) does not exist.") }
            course = course ?? a.courseId
        }
        guard let course else { throw ToolError.invalid("Provide material_id, course_id or assignment_id (the material must be filed under a course).") }
        guard self.course(course) != nil else { throw ToolError.notFound("Course \(course) does not exist.") }
        return try saveClaudeNote(courseId: course, materialId: materialId, assignmentId: assignmentId, kind: kind, title: title, content: content)
    }
}
