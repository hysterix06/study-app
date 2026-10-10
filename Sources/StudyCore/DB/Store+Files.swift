import Foundation

/// What Moodle says about a file besides its name: the section it's in ("Week 3 – Pricing", "Tutorials") and the
/// activity it belongs to ("Tutorial 3 solutions"). Both help sort it and date it.
public struct ImportHints: Equatable, Sendable {
    public var sectionName: String?
    public var moduleName: String?
    public init(sectionName: String? = nil, moduleName: String? = nil) {
        self.sectionName = sectionName; self.moduleName = moduleName
    }
    public static let none = ImportHints()
}

/// Files that just work: each file is filed under its course, sorted into a group and dated without the student being
/// asked, unless the rules really can't tell.
public extension StudyStore {
    // MARK: Filing

    /// The course a file belongs to: a clear match on its code or name, else the only course this term. Nil means ask.
    func suggestCourse(for texts: [String?], courses: [Course]? = nil) -> Int? {
        let all = (courses ?? self.courses()).filter { !$0.archived }
        if let best = CourseMatcher.best(texts.compactMap { $0 }.joined(separator: " "), courses: all) { return best.id }
        let termId = currentTerm()?.id
        let thisTerm = all.filter { termId == nil || $0.termId == termId }
        return thisTerm.count == 1 ? thisTerm[0].id : nil
    }

    /// The current term, creating one from today's date if there is none, so a course can always be added.
    /// August to January is the autumn term, February to July the spring term; the student can rename and redate it.
    @discardableResult
    func ensureCurrentTerm(today: LocalDate? = nil) throws -> Term {
        if let t = currentTerm() { return t }
        let d = today ?? LocalDate.today(tz: timezone)
        let term: Term
        if d.month >= 8 {
            term = Term(name: "Fall \(d.year)", startDate: LocalDate(year: d.year, month: 8, day: 15),
                        endDate: LocalDate(year: d.year + 1, month: 1, day: 31), isCurrent: true)
        } else if d.month == 1 {
            term = Term(name: "Fall \(d.year - 1)", startDate: LocalDate(year: d.year - 1, month: 8, day: 15),
                        endDate: LocalDate(year: d.year, month: 1, day: 31), isCurrent: true)
        } else {
            term = Term(name: "Spring \(d.year)", startDate: LocalDate(year: d.year, month: 2, day: 1),
                        endDate: LocalDate(year: d.year, month: 7, day: 31), isCurrent: true)
        }
        let id = try saveTerm(term)
        return terms().first { $0.id == id } ?? term
    }

    // MARK: Groups

    /// The student moves a file to another group. Their choice is final: nothing automatic changes it afterwards.
    func setFileGroup(_ id: Int, _ group: FileGroup) throws {
        guard let m = material(id) else { throw StoreError.notFound("That file is gone.") }
        let role = group == .notUsed || m.role.group == group ? m.role : group.defaultRole
        try db.execute("""
            UPDATE materials SET role = ?, excluded = ?, role_source = 'user', role_confidence = NULL, sort_reason = NULL,
              read_state = CASE WHEN ? = 1 THEN 'skipped' WHEN read_state = 'skipped' THEN 'pending' ELSE read_state END,
              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, [role.rawValue, group == .notUsed, group == .notUsed, id])
        audit("set_file_group", entity: "material", id: id, detail: group.rawValue)
        pairSolutions(id)
        splitPractice(materialId: id)
    }

    /// The student says exactly what a file is. Undoable.
    func setFileRoleUndoable(_ id: Int, _ role: MaterialRole) throws -> UndoSnapshot {
        let title = material(id)?.title ?? "file"
        return try recordChange("Marked \(title) as \(role.label.lowercased())") { rec in
            try rec.snapshot("materials", ids: [id])
            try setFileGroup(id, role.group)
            try updateMaterial(id, role: role)
        }
    }

    /// The student moves a file to a group ("Not used" sets it aside). Undoable.
    func setFileGroupUndoable(_ id: Int, _ group: FileGroup) throws -> UndoSnapshot {
        let title = material(id)?.title ?? "file"
        return try recordChange(group == .notUsed ? "Set aside \(title)" : "Moved \(title) to \(group.title)") { rec in
            try rec.snapshot("materials", ids: [id])
            try setFileGroup(id, group)
        }
    }

    /// The student says the sort was right ("Looks right" in Needs a look).
    func confirmSort(_ id: Int) throws {
        try db.execute("UPDATE materials SET role_source = 'user', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?", [id])
        audit("confirm_sort", entity: "material", id: id)
    }

    /// Files the rules couldn't place with confidence. Free AI looks at these; whatever it can't place goes to Needs a look.
    func unsureFiles(courseId: Int? = nil) -> [Material] {
        var sql = """
            SELECT * FROM materials WHERE excluded = 0 AND status IN ('ready','inbox') AND role_source IN ('auto','moodle','ai')
              AND role_confidence IS NOT NULL AND role_confidence < ?
            """
        var params: [Any?] = [FileSorter.sureEnough]
        if let courseId { sql += " AND course_id = ?"; params.append(courseId) }
        return ((try? db.query(sql + " ORDER BY imported_at DESC, id DESC", params)) ?? []).map(Material.init)
    }

    /// Saves a sort from the rules or from AI, unless the student already decided.
    func applySort(_ id: Int, role: MaterialRole, confidence: Double, reason: String, source: String) throws {
        try db.execute("""
            UPDATE materials SET role = ?, role_confidence = ?, sort_reason = ?, role_source = ?,
              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ? AND role_source != 'user'
            """, [role.rawValue, confidence, reason, source, id])
        audit("sort_file", entity: "material", id: id, detail: "\(role.rawValue) (\(source), \(Int(confidence * 100))%)")
        pairSolutions(id)
        splitPractice(materialId: id)
    }

    /// Moodle says where a file sits (on a later sync, or for a file first added by hand). Keeps that and, unless the
    /// student already decided, re-sorts the file when it makes the answer clearer.
    func addHints(_ id: Int, _ hints: ImportHints) {
        guard hints != .none, let m = material(id), m.sectionName == nil, m.moduleName == nil else { return }
        _ = try? db.execute("UPDATE materials SET section_name = ?, module_name = ? WHERE id = ?",
                            [hints.sectionName?.nilIfEmpty, hints.moduleName?.nilIfEmpty, id])
        if m.roleSource != "user" {
            let text = chunks(materialId: id, toOrdinal: 3).map { [$0.heading, $0.textMd].compactMap { $0 }.joined(separator: "\n") }
                .joined(separator: "\n")
            let r = FileSorter.sort(.init(filename: m.originalFilename ?? m.title, title: m.title, text: text,
                                          sectionName: hints.sectionName, moduleName: hints.moduleName, kind: m.kind))
            // Files from before v6 have no confidence: their role may be the student's own pick, so only a clear clue moves them.
            let current = m.roleConfidence ?? 0.69
            if r.role == m.role ? r.confidence > current : (r.confidence >= FileSorter.sureEnough && r.confidence > current + 0.05) {
                try? applySort(id, role: r.role, confidence: r.confidence, reason: r.reason, source: r.source)
            }
        }
        refreshTaughtDate(id)
    }

    // MARK: Dates and pairs

    /// The course's class days this term, in order.
    func classDates(courseId: Int) -> [LocalDate] {
        guard let course = course(courseId), let term = terms().first(where: { $0.id == course.termId }) ?? currentTerm() else { return [] }
        let tz = timezone
        let days = occurrences(from: term.startDate, to: term.endDate, includeBusy: false)
            .filter { $0.courseId == courseId && $0.isClass && $0.status != .canceled }
            .map { LocalDate($0.start, tz: tz) }
        return Array(Set(days)).sorted()
    }

    /// Works out when a file was taught from its Moodle section, title and name. Leaves the date empty when nothing says.
    func refreshTaughtDate(_ id: Int, classDates cached: [LocalDate]? = nil) {
        guard let m = material(id), let courseId = m.courseId, let course = course(courseId) else { return }
        let termStart = terms().first { $0.id == course.termId }?.startDate
        let date = TaughtDate.date(texts: [m.sectionName, m.moduleName, m.title, m.originalFilename], termStart: termStart,
                                   classDates: cached ?? classDates(courseId: courseId))
        _ = try? db.execute("UPDATE materials SET taught_on = ? WHERE id = ?", [date?.string, id])
    }

    /// Links a solutions file with the sheet it answers ("Tutorial 3 – Solutions" ↔ "Tutorial 3"), whichever came first.
    func pairSolutions(_ id: Int) {
        guard let m = material(id), let courseId = m.courseId, [.practice, .example, .pastExam].contains(m.role) else { return }
        let siblings = materials(courseId: courseId).filter { $0.id != id && [.practice, .example, .pastExam].contains($0.role) }
        let key = FileSorter.pairKey(m.originalFilename ?? m.title)
        guard !key.isEmpty else { return }
        let isSolutions = Self.isSolutionsFile(m)
        for s in siblings where FileSorter.pairKey(s.originalFilename ?? s.title) == key && Self.isSolutionsFile(s) != isSolutions {
            let (answers, sheet) = isSolutions ? (m, s) : (s, m)
            guard answers.pairsWith != sheet.id else { return }
            _ = try? db.execute("UPDATE materials SET pairs_with = ? WHERE id = ?", [sheet.id, answers.id])
            // A solutions file that arrived first was split into problems of its own: those go, and the sheet's problems
            // pick up their solutions instead.
            if !practiceItems(materialId: answers.id).isEmpty || sheet.readState == "done" { splitPractice(materialId: answers.id) }
            return
        }
    }

    static func isSolutionsFile(_ m: Material) -> Bool {
        FileSorter.firstMatch(FileSorter.solutionPatterns, in: FileSorter.clean(FileSorter.stem(m.originalFilename ?? "") + " " + m.title)) != nil
    }

    // MARK: Files from before v6

    /// Re-sorts files whenever the sorting rules improve, and once after the v6 update. Only automatic decisions are
    /// revisited; a role the student chose, or one free AI settled, stays. Returns how many files changed role.
    ///
    /// Before v6, every file the old rules couldn't place became a "lecture", so tutorials, exercises and solutions were
    /// treated as lectures. Those old roles (and any file without a confidence) only move when the rules are clearly
    /// sure, because the student may have picked them; roles other than "lecture" from before v6 are kept.
    @discardableResult
    /// Whether the rules before v6 would have called this file a reading by its name alone.
    static func oldRulesSaidReading(_ m: Material) -> Bool {
        let s = ((m.originalFilename ?? "") + " " + m.title).lowercased()
        return ["reading", "chapter", "article", "case study"].contains { s.contains($0) }
    }

    func resortFiles() -> Int {
        let version = String(FileSorter.rulesVersion)
        guard setting("file_rules_version") != version else { return 0 }
        // Files from before this version were read the old way; only files added from now on are read automatically.
        if setting("files_read_since") == nil { setSetting("files_read_since", ISO.instant(Date())) }
        let files = ((try? db.query("SELECT * FROM materials WHERE role_source IN ('legacy','auto','moodle')")) ?? []).map(Material.init)
        var moved = 0
        var datesByCourse: [Int: [LocalDate]] = [:]
        for m in files {
            // Placed by the old rules, whose fallbacks were "lecture" and, for any name with "chapter", "reading",
            // "article" or "case study" in it, "reading". Any other old role came from a clear name or from the student,
            // so it stays.
            let oldLecture = m.roleConfidence == nil
            let oldGuess = m.role == .lecture || (m.role == .reading && Self.oldRulesSaidReading(m))
            if oldLecture && !oldGuess {
                _ = try? db.execute("UPDATE materials SET role_source = 'auto' WHERE id = ? AND role_source = 'legacy'", [m.id])
            } else {
                let text = chunks(materialId: m.id, toOrdinal: 3).map { [$0.heading, $0.textMd].compactMap { $0 }.joined(separator: "\n") }
                    .joined(separator: "\n")
                let r = FileSorter.sort(.init(filename: m.originalFilename ?? m.title, title: m.title, text: text,
                                              sectionName: m.sectionName, moduleName: m.moduleName, kind: m.kind))
                let current = m.roleConfidence ?? 0.69
                if r.role != m.role && r.confidence >= max(FileSorter.sureEnough, oldLecture ? 0.7 : 0) {
                    _ = try? db.execute("UPDATE materials SET role = ?, role_source = ?, role_confidence = ?, sort_reason = ? WHERE id = ?",
                                        [r.role.rawValue, r.source, r.confidence, r.reason, m.id])
                    moved += 1
                } else if r.role == m.role && !oldLecture && r.confidence > current {
                    _ = try? db.execute("UPDATE materials SET role_confidence = ?, sort_reason = ?, role_source = ? WHERE id = ?",
                                        [r.confidence, r.reason, r.source, m.id])
                } else if m.roleSource == "legacy" {
                    _ = try? db.execute("UPDATE materials SET role_source = 'auto' WHERE id = ?", [m.id])
                }
            }
            if let c = m.courseId {
                if datesByCourse[c] == nil { datesByCourse[c] = classDates(courseId: c) }
                refreshTaughtDate(m.id, classDates: datesByCourse[c])
            }
        }
        for m in files { pairSolutions(m.id) }
        for m in filesToSplit() { splitPractice(materialId: m.id) }
        setSetting("file_rules_version", version)
        if moved > 0 { audit("resort_files", detail: "rules v\(version): \(moved) of \(files.count) files changed role") }
        return moved
    }
}
