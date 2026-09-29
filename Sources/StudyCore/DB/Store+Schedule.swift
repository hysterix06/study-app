import Foundation

public struct UndoSnapshot {
    public var label: String
    fileprivate var patterns: [ClassPattern]
    fileprivate var exceptionsByPattern: [Int: [ClassException]]
    fileprivate var insertedPatternIds: [Int]
    fileprivate var events: [Event]
    fileprivate var assignments: [Assignment]
    fileprivate var insertedAssignmentIds: [Int]
    fileprivate var deletedAssignments: [Assignment]
}

public extension StudyStore {
    // MARK: Terms

    func terms() -> [Term] { ((try? db.query("SELECT * FROM terms ORDER BY start_date DESC")) ?? []).map(Term.init) }

    func currentTerm() -> Term? {
        if let r = try? db.first("SELECT * FROM terms WHERE is_current = 1 ORDER BY start_date DESC LIMIT 1") { return Term(row: r) }
        let today = LocalDate.today(tz: timezone).string
        if let r = try? db.first("SELECT * FROM terms WHERE start_date <= ? AND end_date >= ? ORDER BY start_date DESC LIMIT 1", [today, today]) { return Term(row: r) }
        return terms().first
    }

    @discardableResult
    func saveTerm(_ t: Term) throws -> Int {
        try db.transaction {
            if t.isCurrent { try db.execute("UPDATE terms SET is_current = 0") }
            if t.id == 0 {
                let id = try db.execute("INSERT INTO terms(name, start_date, end_date, is_current) VALUES(?,?,?,?)",
                                        [t.name, t.startDate, t.endDate, t.isCurrent]).lastInsertId
                audit("create_term", entity: "term", id: id)
                return id
            }
            try db.execute("UPDATE terms SET name=?, start_date=?, end_date=?, is_current=?, updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?",
                           [t.name, t.startDate, t.endDate, t.isCurrent, t.id])
            return t.id
        }
    }

    func deleteTerm(_ id: Int) throws {
        let courses = try db.scalarInt("SELECT count(*) FROM courses WHERE term_id = ?", [id])
        if courses > 0 { throw StoreError.inUse("This term still has \(courses) course\(courses == 1 ? "" : "s"). Move or archive them first.") }
        try db.execute("DELETE FROM terms WHERE id = ?", [id])
    }

    func breaks(termId: Int? = nil) -> [TermBreak] {
        let rows = termId.map { (try? db.query("SELECT * FROM term_breaks WHERE term_id = ? ORDER BY start_date", [$0])) ?? [] }
            ?? ((try? db.query("SELECT * FROM term_breaks ORDER BY start_date")) ?? [])
        return rows.map(TermBreak.init)
    }

    @discardableResult
    func saveBreak(_ b: TermBreak) throws -> Int {
        if b.id == 0 {
            return try db.execute("INSERT INTO term_breaks(term_id, start_date, end_date, label) VALUES(?,?,?,?)",
                                  [b.termId, b.startDate, b.endDate, b.label]).lastInsertId
        }
        try db.execute("UPDATE term_breaks SET start_date=?, end_date=?, label=? WHERE id=?", [b.startDate, b.endDate, b.label, b.id])
        return b.id
    }

    func deleteBreak(_ id: Int) throws { try db.execute("DELETE FROM term_breaks WHERE id = ?", [id]) }

    // MARK: Courses

    func courses(includeArchived: Bool = false) -> [Course] {
        let order = "COALESCE(NULLIF(short_name, ''), NULLIF(name, ''), code) COLLATE NOCASE"
        let sql = includeArchived ? "SELECT * FROM courses ORDER BY archived, \(order)"
            : "SELECT * FROM courses WHERE archived = 0 ORDER BY \(order)"
        return ((try? db.query(sql)) ?? []).map(Course.init)
    }

    func courseMap() -> [Int: Course] { Dictionary(uniqueKeysWithValues: courses(includeArchived: true).map { ($0.id, $0) }) }

    func course(_ id: Int) -> Course? { (try? db.first("SELECT * FROM courses WHERE id = ?", [id])).map(Course.init) }

    @discardableResult
    func saveCourse(_ c: Course) throws -> Int {
        if c.id == 0 {
            let color = c.color.isEmpty ? nextCourseColor() : c.color
            let id = try db.execute("""
                INSERT INTO courses(term_id, code, name, short_name, instructor, color, aliases, kind, grade_scale, target_grade, pass_mark, moodle_id, archived)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [c.termId, c.code?.nilIfEmpty, c.name, c.shortName?.nilIfEmpty, c.instructor?.nilIfEmpty, color, c.aliases?.nilIfEmpty, c.kind,
                      c.gradeScale.rawValue, c.targetGrade, c.passMark, c.moodleId, c.archived]).lastInsertId
            audit("create_course", entity: "course", id: id, detail: c.name)
            return id
        }
        try db.execute("""
            UPDATE courses SET term_id=?, code=?, name=?, short_name=?, instructor=?, color=?, aliases=?, kind=?, grade_scale=?, target_grade=?,
              pass_mark=?, moodle_id=?, archived=?, updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?
            """, [c.termId, c.code?.nilIfEmpty, c.name, c.shortName?.nilIfEmpty, c.instructor?.nilIfEmpty, c.color, c.aliases?.nilIfEmpty, c.kind,
                  c.gradeScale.rawValue, c.targetGrade, c.passMark, c.moodleId, c.archived, c.id])
        return c.id
    }

    func nextCourseColor() -> String {
        let used = Set(courses().map(\.color))
        return CoursePalette.allCases.first { !used.contains($0.rawValue) }?.rawValue
            ?? CoursePalette.allCases[courses().count % CoursePalette.allCases.count].rawValue
    }

    func deleteCourse(_ id: Int) throws {
        try db.transaction {
            try db.execute("DELETE FROM courses WHERE id = ?", [id])
            audit("delete_course", entity: "course", id: id)
        }
    }

    // MARK: Patterns, exceptions, events

    func patterns(courseId: Int? = nil) -> [ClassPattern] {
        let rows = courseId.map { (try? db.query("SELECT * FROM class_patterns WHERE course_id = ? ORDER BY weekday, start_time", [$0])) ?? [] }
            ?? ((try? db.query("SELECT * FROM class_patterns ORDER BY weekday, start_time")) ?? [])
        return rows.map(ClassPattern.init)
    }

    func exceptions() -> [ClassException] { ((try? db.query("SELECT * FROM class_exceptions")) ?? []).map(ClassException.init) }

    func events(from: Date? = nil, to: Date? = nil) -> [Event] {
        if let from, let to {
            return ((try? db.query("SELECT * FROM events WHERE start_at >= ? AND start_at < ? ORDER BY start_at",
                                   [ISO.instant(from.adding(days: -1)), ISO.instant(to.adding(days: 1))])) ?? []).map(Event.init)
        }
        return ((try? db.query("SELECT * FROM events ORDER BY start_at")) ?? []).map(Event.init)
    }

    @discardableResult
    func savePattern(_ p: ClassPattern) throws -> Int {
        if p.id == 0 {
            let id = try db.execute("""
                INSERT INTO class_patterns(course_id, weekday, start_time, end_time, location, valid_from, valid_to, timezone, external_uid, user_modified)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """, [p.courseId, p.weekday, p.startTime, p.endTime, p.location, p.validFrom, p.validTo, p.timezone, p.externalUid, p.userModified]).lastInsertId
            audit("create_pattern", entity: "class_pattern", id: id)
            return id
        }
        try db.execute("""
            UPDATE class_patterns SET course_id=?, weekday=?, start_time=?, end_time=?, location=?, valid_from=?, valid_to=?, timezone=?,
              external_uid=?, user_modified=?, updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?
            """, [p.courseId, p.weekday, p.startTime, p.endTime, p.location, p.validFrom, p.validTo, p.timezone, p.externalUid, p.userModified, p.id])
        return p.id
    }

    func deletePattern(_ id: Int) throws { try db.execute("DELETE FROM class_patterns WHERE id = ?", [id]) }

    @discardableResult
    func saveEvent(_ e: Event) throws -> Int {
        let start = e.allDay ? ISO.instant(LocalDate(e.start, tz: TimeZone(identifier: "UTC")!).utcMidnight) : ISO.instant(e.start)
        if e.id == 0 {
            return try db.execute("""
                INSERT INTO events(course_id, title, kind, start_at, end_at, all_day, location, notes, canceled, source, calendar_source_id, external_uid, user_modified)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [e.courseId, e.title, e.kind, start, e.end.map { ISO.instant($0) }, e.allDay, e.location, e.notes, e.canceled,
                      e.source, e.calendarSourceId, e.externalUid, e.userModified]).lastInsertId
        }
        try db.execute("""
            UPDATE events SET course_id=?, title=?, kind=?, start_at=?, end_at=?, all_day=?, location=?, notes=?, canceled=?, user_modified=?,
              updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?
            """, [e.courseId, e.title, e.kind, start, e.end.map { ISO.instant($0) }, e.allDay, e.location, e.notes, e.canceled, e.userModified, e.id])
        return e.id
    }

    func deleteEvent(_ id: Int) throws { try db.execute("DELETE FROM events WHERE id = ?", [id]) }

    /// Expanded calendar for a date range, in the display zone.
    func occurrences(from: LocalDate, to: LocalDate, includeBusy: Bool = true) -> [Occurrence] {
        let tz = timezone
        let evs = events(from: from.at(LocalTime(hour: 0, minute: 0), tz: tz), to: to.adding(days: 1).at(LocalTime(hour: 0, minute: 0), tz: tz))
            .filter { includeBusy || $0.kind != "busy" }
        return ScheduleEngine.expand(from: from, to: to, patterns: patterns(), exceptions: exceptions(), events: evs,
                                     breaks: breaks(), courses: courseMap(), displayTimezone: tz)
    }

    func nextClass(after now: Date = Date()) -> Occurrence? {
        let tz = timezone
        let today = LocalDate(now, tz: tz)
        return occurrences(from: today, to: today.adding(days: 14), includeBusy: false)
            .first { $0.isClass && $0.status != .canceled && $0.end > now }
    }

    // MARK: Applying schedule edits (one transaction, undoable)

    func apply(_ plan: EditPlan, label: String) throws -> UndoSnapshot {
        let patternIds = Set(plan.mutations.compactMap { m -> Int? in
            switch m {
            case .updatePattern(let p): return p.id
            case .deletePattern(let id): return id
            case .upsertException(let e): return e.patternId
            case .deleteException(let id): return (try? db.scalarInt("SELECT pattern_id FROM class_exceptions WHERE id = ?", [id]))
            default: return nil
            }
        })
        let allPatterns = patterns()
        let snapPatterns = allPatterns.filter { patternIds.contains($0.id) }
        let allEx = exceptions()
        var exBy: [Int: [ClassException]] = [:]
        for id in patternIds { exBy[id] = allEx.filter { $0.patternId == id } }
        let eventIds = plan.mutations.compactMap { m -> Int? in if case .updateEvent(let e) = m { return e.id }; return nil }
        let snapEvents = eventIds.compactMap { id in (try? db.first("SELECT * FROM events WHERE id = ?", [id])).map(Event.init) }

        var inserted: [Int] = []
        try db.transaction {
            for m in plan.mutations {
                switch m {
                case .upsertException(let ex):
                    try db.execute("""
                        INSERT INTO class_exceptions(pattern_id, original_date, kind, new_date, new_start_time, new_end_time, new_location, note)
                        VALUES(?,?,?,?,?,?,?,?)
                        ON CONFLICT(pattern_id, original_date) DO UPDATE SET kind=excluded.kind, new_date=excluded.new_date,
                          new_start_time=excluded.new_start_time, new_end_time=excluded.new_end_time, new_location=excluded.new_location,
                          note=excluded.note, updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
                        """, [ex.patternId, ex.originalDate, ex.kind.rawValue, ex.newDate, ex.newStartTime, ex.newEndTime, ex.newLocation, ex.note])
                case .deleteException(let id):
                    try db.execute("DELETE FROM class_exceptions WHERE id = ?", [id])
                case .updatePattern(let p):
                    try savePattern(p)
                case .insertPattern(let p, let reparent):
                    var np = p; np.id = 0
                    let id = try savePattern(np)
                    inserted.append(id)
                    for exId in reparent { try db.execute("UPDATE class_exceptions SET pattern_id = ? WHERE id = ?", [id, exId]) }
                case .deletePattern(let id):
                    try deletePattern(id)
                case .updateEvent(let e):
                    try saveEvent(e)
                }
            }
            audit("schedule_edit", entity: "schedule", detail: label)
        }
        return UndoSnapshot(label: label, patterns: snapPatterns, exceptionsByPattern: exBy, insertedPatternIds: inserted,
                            events: snapEvents, assignments: [], insertedAssignmentIds: [], deletedAssignments: [])
    }

    /// Restores exactly the rows captured before an edit.
    func undo(_ s: UndoSnapshot) throws {
        try db.transaction {
            for id in s.insertedPatternIds { try deletePattern(id) }
            for p in s.patterns {
                let exists = try db.scalarInt("SELECT count(*) FROM class_patterns WHERE id = ?", [p.id]) > 0
                if exists { try savePattern(p) } else {
                    try db.execute("""
                        INSERT INTO class_patterns(id, course_id, weekday, start_time, end_time, location, valid_from, valid_to, timezone, external_uid, user_modified)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?)
                        """, [p.id, p.courseId, p.weekday, p.startTime, p.endTime, p.location, p.validFrom, p.validTo, p.timezone, p.externalUid, p.userModified])
                }
            }
            for (pid, exs) in s.exceptionsByPattern {
                try db.execute("DELETE FROM class_exceptions WHERE pattern_id = ?", [pid])
                for ex in exs {
                    try db.execute("""
                        INSERT OR REPLACE INTO class_exceptions(id, pattern_id, original_date, kind, new_date, new_start_time, new_end_time, new_location, note)
                        VALUES(?,?,?,?,?,?,?,?,?)
                        """, [ex.id, ex.patternId, ex.originalDate, ex.kind.rawValue, ex.newDate, ex.newStartTime, ex.newEndTime, ex.newLocation, ex.note])
                }
            }
            for e in s.events { try saveEvent(e) }
            for id in s.insertedAssignmentIds { try db.execute("DELETE FROM assignments WHERE id = ?", [id]) }
            for a in s.assignments { try saveAssignment(a, markModified: false) }
            for a in s.deletedAssignments { try restoreAssignment(a) }
            audit("undo", detail: s.label)
        }
    }

    func assignmentSnapshot(_ ids: [Int], label: String, inserted: [Int] = [], deleted: [Assignment] = []) -> UndoSnapshot {
        let rows = ids.compactMap { assignment($0) }
        return UndoSnapshot(label: label, patterns: [], exceptionsByPattern: [:], insertedPatternIds: [], events: [],
                            assignments: rows, insertedAssignmentIds: inserted, deletedAssignments: deleted)
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case inUse(String), notFound(String), invalid(String)
    public var description: String {
        switch self { case .inUse(let m), .notFound(let m), .invalid(let m): return m }
    }
}
