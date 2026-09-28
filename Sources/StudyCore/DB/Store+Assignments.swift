import Foundation

public struct AssignmentFilter {
    public var courseId: Int?
    public var statuses: [AssignmentStatus]?
    public var kinds: [AssignmentKind]?
    public var dueFrom: Date?
    public var dueTo: Date?
    public var includeProposed = false
    public var onlyProposed = false
    public init(courseId: Int? = nil, statuses: [AssignmentStatus]? = nil, kinds: [AssignmentKind]? = nil, dueFrom: Date? = nil,
                dueTo: Date? = nil, includeProposed: Bool = false, onlyProposed: Bool = false) {
        self.courseId = courseId; self.statuses = statuses; self.kinds = kinds; self.dueFrom = dueFrom; self.dueTo = dueTo
        self.includeProposed = includeProposed; self.onlyProposed = onlyProposed
    }
}

public extension StudyStore {
    func assignments(_ f: AssignmentFilter = AssignmentFilter()) -> [Assignment] {
        var sql = "SELECT * FROM assignments WHERE dismissed = 0"
        var params: [Any?] = []
        if f.onlyProposed { sql += " AND confirmed = 0" } else if !f.includeProposed { sql += " AND confirmed = 1" }
        if let c = f.courseId { sql += " AND course_id = ?"; params.append(c) }
        if let s = f.statuses, !s.isEmpty { sql += " AND status IN (\(s.map { _ in "?" }.joined(separator: ",")))"; params += s.map(\.rawValue) }
        if let k = f.kinds, !k.isEmpty { sql += " AND kind IN (\(k.map { _ in "?" }.joined(separator: ",")))"; params += k.map(\.rawValue) }
        if let from = f.dueFrom { sql += " AND due_at >= ?"; params.append(ISO.instant(from)) }
        if let to = f.dueTo { sql += " AND due_at <= ?"; params.append(ISO.instant(to)) }
        sql += " ORDER BY due_at IS NULL, due_at, id"
        return ((try? db.query(sql, params)) ?? []).map(Assignment.init)
    }

    func assignment(_ id: Int) -> Assignment? {
        (try? db.first("SELECT * FROM assignments WHERE id = ?", [id])).map(Assignment.init)
    }

    @discardableResult
    func saveAssignment(_ a: Assignment, markModified: Bool = true) throws -> Int {
        if a.id == 0 {
            let id = try db.execute("""
                INSERT INTO assignments(course_id, title, description, kind, due_at, status, weight_pct, est_hours, score, max_score,
                  min_pass_pct, group_members, rubric_material_id, confirmed, dismissed, source, source_material_id, source_locator,
                  external_uid, url, submitted_at, user_modified)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [a.courseId, a.title, a.description, a.kind.rawValue, a.dueAt.map { ISO.instant($0) }, a.status.rawValue,
                      a.weightPct, a.estHours, a.score, a.maxScore, a.minPassPct, a.groupMembers, a.rubricMaterialId, a.confirmed,
                      a.dismissed, a.source, a.sourceMaterialId, a.sourceLocator, a.externalUid, a.url,
                      a.submittedAt.map { ISO.instant($0) }, a.userModified]).lastInsertId
            audit("create_assignment", entity: "assignment", id: id, detail: a.title)
            return id
        }
        let modified = markModified ? (a.source != "manual" ? true : a.userModified) : a.userModified
        try db.execute("""
            UPDATE assignments SET course_id=?, title=?, description=?, kind=?, due_at=?, status=?, weight_pct=?, est_hours=?, score=?,
              max_score=?, min_pass_pct=?, group_members=?, rubric_material_id=?, confirmed=?, dismissed=?, source_material_id=?,
              source_locator=?, url=?, submitted_at=?, user_modified=?, updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?
            """, [a.courseId, a.title, a.description, a.kind.rawValue, a.dueAt.map { ISO.instant($0) }, a.status.rawValue, a.weightPct,
                  a.estHours, a.score, a.maxScore, a.minPassPct, a.groupMembers, a.rubricMaterialId, a.confirmed, a.dismissed,
                  a.sourceMaterialId, a.sourceLocator, a.url, a.submittedAt.map { ISO.instant($0) }, modified, a.id])
        return a.id
    }

    func restoreAssignment(_ a: Assignment) throws {
        try db.execute("""
            INSERT OR REPLACE INTO assignments(id, course_id, title, description, kind, due_at, status, weight_pct, est_hours, score, max_score,
              min_pass_pct, group_members, rubric_material_id, confirmed, dismissed, source, source_material_id, source_locator,
              external_uid, url, submitted_at, user_modified)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [a.id, a.courseId, a.title, a.description, a.kind.rawValue, a.dueAt.map { ISO.instant($0) }, a.status.rawValue,
                  a.weightPct, a.estHours, a.score, a.maxScore, a.minPassPct, a.groupMembers, a.rubricMaterialId, a.confirmed,
                  a.dismissed, a.source, a.sourceMaterialId, a.sourceLocator, a.externalUid, a.url,
                  a.submittedAt.map { ISO.instant($0) }, a.userModified])
    }

    func setStatus(_ id: Int, _ status: AssignmentStatus) throws {
        guard var a = assignment(id) else { return }
        a.status = status
        if status == .submitted && a.submittedAt == nil { a.submittedAt = Date() }
        if status.isOpen { a.submittedAt = nil }
        try saveAssignment(a)
    }

    /// Deleting is undoable instead of gated by a dialog (§7.2).
    func deleteAssignment(_ id: Int) throws -> UndoSnapshot? {
        guard let a = assignment(id) else { return nil }
        try db.transaction {
            if a.externalUid != nil {
                // Keep a tombstone so re-import does not bring it back.
                try db.execute("UPDATE assignments SET dismissed = 1, user_modified = 1 WHERE id = ?", [id])
            } else {
                try db.execute("DELETE FROM assignments WHERE id = ?", [id])
            }
            audit("delete_assignment", entity: "assignment", id: id, detail: a.title)
        }
        return assignmentSnapshot([], label: "Deleted \(a.title)", deleted: [a])
    }

    func confirmProposed(_ id: Int, courseId: Int? = nil) throws {
        guard var a = assignment(id) else { return }
        if let courseId { a.courseId = courseId }
        guard a.courseId != nil else { throw StoreError.invalid("Choose a course first.") }
        a.confirmed = true
        try saveAssignment(a, markModified: false)
        audit("confirm_assignment", entity: "assignment", id: id)
    }

    func dismissProposed(_ id: Int) throws {
        try db.execute("UPDATE assignments SET dismissed = 1 WHERE id = ?", [id])
        audit("dismiss_assignment", entity: "assignment", id: id)
    }

    // MARK: Conflicts

    func conflicts() -> [Conflict] {
        ((try? db.query("SELECT * FROM conflicts WHERE resolved_at IS NULL ORDER BY id")) ?? []).map(Conflict.init)
    }

    /// "Keep mine" leaves the row untouched; "Use theirs" applies the incoming values.
    func resolveConflict(_ id: Int, acceptIncoming: Bool) throws {
        guard let row = try db.first("SELECT * FROM conflicts WHERE id = ?", [id]) else { return }
        let c = Conflict(row: row)
        try db.transaction {
            if acceptIncoming, let inc = JSON.parse(c.incomingJson) as? [String: Any] {
                switch c.entity {
                case "assignment":
                    if var a = assignment(c.entityId) {
                        if let t = inc["title"] as? String { a.title = t }
                        a.dueAt = (inc["due_at"] as? String).flatMap { ISO.parse($0) }
                        a.userModified = false
                        try saveAssignment(a, markModified: false)
                    }
                case "event":
                    if let r = try db.first("SELECT * FROM events WHERE id = ?", [c.entityId]) {
                        var e = Event(row: r)
                        if let t = inc["title"] as? String { e.title = t }
                        if let s = (inc["start_at"] as? String).flatMap({ ISO.parse($0) }) { e.start = s }
                        e.end = (inc["end_at"] as? String).flatMap { ISO.parse($0) }
                        e.location = inc["location"] as? String
                        e.userModified = false
                        try saveEvent(e)
                    }
                case "class_pattern":
                    if let r = try db.first("SELECT * FROM class_patterns WHERE id = ?", [c.entityId]) {
                        var p = ClassPattern(row: r)
                        if let w = (inc["weekday"] as? NSNumber)?.intValue { p.weekday = w }
                        if let s = (inc["start_time"] as? String).flatMap(LocalTime.init) { p.startTime = s }
                        if let e = (inc["end_time"] as? String).flatMap(LocalTime.init) { p.endTime = e }
                        p.location = (inc["location"] as? String)?.nilIfEmpty
                        if let f = (inc["valid_from"] as? String).flatMap(LocalDate.init) { p.validFrom = f }
                        if let t = (inc["valid_to"] as? String).flatMap(LocalDate.init) { p.validTo = t }
                        p.userModified = false
                        try savePattern(p)
                    }
                default: break
                }
            }
            try db.execute("UPDATE conflicts SET resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?", [id])
            audit("resolve_conflict", entity: c.entity, id: c.entityId, detail: acceptIncoming ? "incoming" : "kept")
        }
    }

    // MARK: Study blocks

    func studyBlocks(from: Date? = nil, to: Date? = nil, statuses: [String] = ["proposed", "planned", "done"]) -> [StudyBlock] {
        var sql = "SELECT * FROM study_blocks WHERE status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"
        var params: [Any?] = statuses
        if let from { sql += " AND planned_start >= ?"; params.append(ISO.instant(from)) }
        if let to { sql += " AND planned_start < ?"; params.append(ISO.instant(to)) }
        sql += " ORDER BY planned_start"
        return ((try? db.query(sql, params)) ?? []).map(StudyBlock.init)
    }

    @discardableResult
    func saveStudyBlock(_ b: StudyBlock) throws -> Int {
        if b.id == 0 {
            return try db.execute("""
                INSERT INTO study_blocks(course_id, assignment_id, planned_start, planned_minutes, focus, status, created_by)
                VALUES(?,?,?,?,?,?,?)
                """, [b.courseId, b.assignmentId, ISO.instant(b.plannedStart), b.plannedMinutes, b.focus, b.status, b.createdBy]).lastInsertId
        }
        try db.execute("""
            UPDATE study_blocks SET course_id=?, assignment_id=?, planned_start=?, planned_minutes=?, focus=?, status=?,
              updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?
            """, [b.courseId, b.assignmentId, ISO.instant(b.plannedStart), b.plannedMinutes, b.focus, b.status, b.id])
        return b.id
    }

    func setBlockStatus(_ id: Int, _ status: String) throws {
        try db.execute("UPDATE study_blocks SET status = ?, updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?", [status, id])
    }

    /// Replaces untouched planner proposals with a fresh plan.
    func replacePlannerProposals(_ blocks: [StudyBlock]) throws {
        try db.transaction {
            try db.execute("DELETE FROM study_blocks WHERE status = 'proposed' AND created_by = 'planner'")
            for b in blocks { try saveStudyBlock(b) }
        }
    }
}
