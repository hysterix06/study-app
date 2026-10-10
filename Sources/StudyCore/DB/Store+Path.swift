import Foundation

/// A path as the course builder (or the free AI, or the app itself) lays it out.
public struct PathInput {
    public struct Source {
        public var materialId: Int
        /// Empty means the whole file.
        public var chunkIds: [Int]
        public init(materialId: Int, chunkIds: [Int] = []) { self.materialId = materialId; self.chunkIds = chunkIds }
    }
    public struct Topic {
        /// An existing topic's id, so a rebuilt path keeps it (and its progress).
        public var id: Int?
        public var key: String?
        public var title: String
        public var summary: String?
        public var objectives: [String]
        /// Other topics in this path, by key, title or id.
        public var prereqs: [String]
        public var estMinutes: Int?
        public var emphasis: Int?
        public var beyondCourse: Bool
        public var sources: [Source]
        public init(id: Int? = nil, key: String? = nil, title: String, summary: String? = nil, objectives: [String] = [], prereqs: [String] = [],
                    estMinutes: Int? = nil, emphasis: Int? = nil, beyondCourse: Bool = false, sources: [Source] = []) {
            self.id = id; self.key = key; self.title = title; self.summary = summary; self.objectives = objectives; self.prereqs = prereqs
            self.estMinutes = estMinutes; self.emphasis = emphasis; self.beyondCourse = beyondCourse; self.sources = sources
        }
    }
    public struct Unit {
        public var title: String
        public var summary: String?
        public var topics: [Topic]
        public init(title: String, summary: String? = nil, topics: [Topic]) { self.title = title; self.summary = summary; self.topics = topics }
    }
    /// Which topics a deadline or exam covers.
    public struct Assessment {
        public var assignmentId: Int
        public var topics: [String]
        public init(assignmentId: Int, topics: [String]) { self.assignmentId = assignmentId; self.topics = topics }
    }

    public var units: [Unit]
    public var approachMd: String?
    public var anglesMd: String?
    public var resources: [String]
    public var assessments: [Assessment]

    public init(units: [Unit], approachMd: String? = nil, anglesMd: String? = nil, resources: [String] = [], assessments: [Assessment] = []) {
        self.units = units; self.approachMd = approachMd; self.anglesMd = anglesMd; self.resources = resources; self.assessments = assessments
    }
}

public struct PathSaveResult {
    public var created = 0
    public var updated = 0
    /// Topics no longer in the path that the student hadn't started.
    public var retired = 0
    /// Topics no longer in the path that the student had started: kept, in an "Also studied" unit.
    public var kept = 0
    public var warnings: [String] = []
    /// Every key, title and id the input used → the topic id.
    public var topicIds: [String: Int] = [:]

    public var json: [String: Any] {
        var d: [String: Any] = ["created": created, "updated": updated, "retired": retired, "kept": kept]
        if !warnings.isEmpty { d["warnings"] = warnings }
        return d
    }
}

public extension StudyStore {
    // MARK: Reading

    func path(courseId: Int) -> CoursePath? {
        (try? db.first("SELECT * FROM course_paths WHERE course_id = ?", [courseId])).map(CoursePath.init)
    }

    func units(courseId: Int) -> [PathUnit] {
        ((try? db.query("""
            SELECT u.* FROM path_units u JOIN course_paths p ON p.id = u.path_id WHERE p.course_id = ? ORDER BY u.ordinal, u.id
            """, [courseId])) ?? []).map(PathUnit.init)
    }

    /// In path order: by unit, then by topic.
    func topics(courseId: Int, includeRetired: Bool = false) -> [PathTopic] {
        ((try? db.query("""
            SELECT t.* FROM path_topics t LEFT JOIN path_units u ON u.id = t.unit_id
            WHERE t.course_id = ? AND (t.retired = 0 OR ?)
            ORDER BY u.ordinal IS NULL, u.ordinal, t.ordinal, t.id
            """, [courseId, includeRetired])) ?? []).map(PathTopic.init)
    }

    func topic(_ id: Int) -> PathTopic? { (try? db.first("SELECT * FROM path_topics WHERE id = ?", [id])).map(PathTopic.init) }

    /// "2.3": the unit's place in the path, then the topic's place in its unit.
    func topicNumbers(courseId: Int) -> [Int: String] {
        let units = self.units(courseId: courseId)
        var out: [Int: String] = [:]
        let byUnit = Dictionary(grouping: topics(courseId: courseId), by: { $0.unitId ?? 0 })
        for (i, u) in units.enumerated() {
            for (j, t) in (byUnit[u.id] ?? []).enumerated() { out[t.id] = "\(i + 1).\(j + 1)" }
        }
        return out
    }

    func notebook(topicId: Int) -> TopicNotebook? {
        (try? db.first("SELECT * FROM topic_notebook WHERE topic_id = ?", [topicId])).map(TopicNotebook.init)
    }

    func notebooks(courseId: Int) -> [Int: TopicNotebook] {
        let rows = (try? db.query("SELECT n.* FROM topic_notebook n JOIN path_topics t ON t.id = n.topic_id WHERE t.course_id = ?", [courseId])) ?? []
        return Dictionary(rows.map(TopicNotebook.init).map { ($0.topicId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func lesson(topicId: Int) -> TopicLesson? {
        (try? db.first("SELECT * FROM topic_lessons WHERE topic_id = ?", [topicId])).map(TopicLesson.init)
    }

    func coverage(topicId: Int) -> [TopicCoverage] {
        ((try? db.query("SELECT * FROM topic_coverage WHERE topic_id = ?", [topicId])) ?? []).map(TopicCoverage.init)
    }

    func coverage(materialId: Int) -> [TopicCoverage] {
        ((try? db.query("SELECT * FROM topic_coverage WHERE material_id = ?", [materialId])) ?? []).map(TopicCoverage.init)
    }

    func assessmentTopicIds(assignmentId: Int) -> [Int] {
        ((try? db.query("SELECT topic_id FROM assessment_topics WHERE assignment_id = ?", [assignmentId])) ?? []).map { $0.i("topic_id") }
    }

    // MARK: Saving a path

    /// "Price elasticity of demand" → "price-elasticity-of-demand". A rebuilt path finds its topics again by this key.
    static func topicKey(_ s: String) -> String {
        let k = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"^\s*\d+(\.\d+)*[.)]?\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(k.prefix(60))
    }

    static let tierRank = ["skeleton": 0, "basic": 1, "full": 2]

    /// Saves a course's path, merging with the one it replaces: topics are matched by id, then by key, so their
    /// progress, notebook pages, cards and practice stay with them. A topic that drops out is kept (in "Also studied") if
    /// the student had started it, and retired otherwise. Nothing is deleted. A fuller path is never replaced by a
    /// simpler one (a basic version doesn't overwrite the course builder's).
    @discardableResult
    func savePath(courseId: Int, _ input: PathInput, tier: String, builtWith: String?, createdBy: String = "claude") throws -> PathSaveResult {
        guard course(courseId) != nil else { throw StoreError.notFound("Course \(courseId) does not exist.") }
        guard let rank = Self.tierRank[tier] else { throw StoreError.invalid("tier must be skeleton, basic or full.") }
        let all = input.units.flatMap(\.topics)
        guard (1...16).contains(input.units.count) else { throw StoreError.invalid("A path has 1 to 16 units.") }
        guard (1...80).contains(all.count) else { throw StoreError.invalid("A path has 1 to 80 topics.") }
        if let old = path(courseId: courseId), (Self.tierRank[old.tier] ?? 0) > rank {
            throw StoreError.inUse("This course already has a fuller path; a \(tier) one doesn't replace it.")
        }
        var result = PathSaveResult()
        try db.transaction {
            let existing = topics(courseId: courseId, includeRetired: true)
            let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            var byKey = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let pathId: Int
            if let p = path(courseId: courseId) {
                try db.execute("""
                    UPDATE course_paths SET tier = ?, built_with = ?, approach_md = COALESCE(?, approach_md), angles_md = COALESCE(?, angles_md),
                      resources_json = ?, version = version + 1, stale = 0, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
                    """, [tier, builtWith, input.approachMd.map { String($0.prefix(8_000)) }, input.anglesMd.map { String($0.prefix(8_000)) },
                          JSON.string(Array(input.resources.prefix(12)).map { String($0.prefix(200)) }), p.id])
                pathId = p.id
            } else {
                pathId = try db.execute("""
                    INSERT INTO course_paths(course_id, tier, built_with, approach_md, angles_md, resources_json) VALUES(?,?,?,?,?,?)
                    """, [courseId, tier, builtWith, input.approachMd.map { String($0.prefix(8_000)) }, input.anglesMd.map { String($0.prefix(8_000)) },
                          JSON.string(Array(input.resources.prefix(12)).map { String($0.prefix(200)) })]).lastInsertId
            }
            try db.execute("DELETE FROM path_units WHERE path_id = ?", [pathId])

            var used = Set<Int>()
            var pending: [(id: Int, input: PathInput.Topic)] = []
            for (ui, unit) in input.units.enumerated() {
                let unitTitle = unit.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let unitId = try db.execute("INSERT INTO path_units(path_id, ordinal, title, summary) VALUES(?,?,?,?)",
                                            [pathId, ui + 1, String((unitTitle.isEmpty ? "Unit \(ui + 1)" : unitTitle).prefix(120)),
                                             unit.summary.map { String($0.prefix(600)) }]).lastInsertId
                for (ti, t) in unit.topics.enumerated() {
                    let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { result.warnings.append("A topic in \(unitTitle) had no title."); continue }
                    var key = Self.topicKey(t.key?.nilIfEmpty ?? title)
                    if key.isEmpty { key = "topic-\(ui + 1)-\(ti + 1)" }
                    var match = t.id.flatMap { byId[$0] } ?? byKey[key] ?? byKey[Self.topicKey(title)]
                    if let m = match, used.contains(m.id) { match = nil }
                    let id: Int
                    let objectives = JSON.string(Array(t.objectives.prefix(8)).map { String($0.prefix(240)) })
                    let minutes = t.estMinutes.map { min(240, max(5, $0)) }
                    let emphasis = t.emphasis.map { min(3, max(0, $0)) }
                    if let m = match {
                        // Keep the topic's own key if the new one belongs to another topic.
                        if let other = byKey[key], other.id != m.id { key = m.key }
                        try db.execute("""
                            UPDATE path_topics SET unit_id = ?, ordinal = ?, key = ?, title = ?, summary = ?, objectives_json = ?,
                              est_minutes = COALESCE(?, est_minutes), emphasis = COALESCE(?, emphasis), beyond_course = ?, retired = 0,
                              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
                            """, [unitId, ti + 1, key, String(title.prefix(160)), t.summary.map { String($0.prefix(800)) }, objectives,
                                  minutes, emphasis, t.beyondCourse, m.id])
                        id = m.id
                        result.updated += 1
                    } else {
                        var unique = key, n = 2
                        while byKey[unique] != nil { unique = "\(key)-\(n)"; n += 1 }
                        key = unique
                        id = try db.execute("""
                            INSERT INTO path_topics(course_id, unit_id, ordinal, key, title, summary, objectives_json, est_minutes, emphasis,
                              beyond_course, created_by)
                            VALUES(?,?,?,?,?,?,?,?,?,?,?)
                            """, [courseId, unitId, ti + 1, key, String(title.prefix(160)), t.summary.map { String($0.prefix(800)) }, objectives,
                                  minutes ?? 25, emphasis ?? 1, t.beyondCourse, createdBy]).lastInsertId
                        result.created += 1
                    }
                    byKey[key] = topic(id)
                    used.insert(id)
                    result.topicIds[key] = id
                    result.topicIds[Self.topicKey(title)] = id
                    if let k = t.key { result.topicIds[Self.topicKey(k)] = id }
                    if let old = t.id { result.topicIds[String(old)] = id }
                    pending.append((id, t))
                }
            }

            // Topics that dropped out: started ones are kept where the student can find them; the rest retire.
            let leftover = existing.filter { !used.contains($0.id) && !$0.retired }
            let started = leftover.filter { topicHasProgress($0) }
            if !started.isEmpty {
                let unitId = try db.execute("INSERT INTO path_units(path_id, ordinal, title, summary) VALUES(?,?,'Also studied',?)",
                                            [pathId, input.units.count + 1, "Topics you'd started before the path changed."]).lastInsertId
                for (i, t) in started.enumerated() {
                    try db.execute("UPDATE path_topics SET unit_id = ?, ordinal = ?, retired = 0 WHERE id = ?", [unitId, i + 1, t.id])
                }
                result.kept = started.count
            }
            for t in leftover where !topicHasProgress(t) {
                try db.execute("UPDATE path_topics SET retired = 1, unit_id = NULL WHERE id = ?", [t.id])
                // Nothing the student did hangs on it, so its problems and files are free to link to the new topics.
                try db.execute("UPDATE practice_items SET topic_id = NULL WHERE topic_id = ?", [t.id])
                try db.execute("DELETE FROM topic_coverage WHERE topic_id = ?", [t.id])
                result.retired += 1
            }

            // Prerequisites, kept a DAG: an edge that would close a loop is dropped.
            var edges: [Int: Set<Int>] = [:]   // topic → its prerequisites
            func reaches(_ from: Int, _ to: Int) -> Bool {
                var stack = [from], seen = Set<Int>()
                while let n = stack.popLast() {
                    if n == to { return true }
                    if seen.insert(n).inserted { stack.append(contentsOf: edges[n] ?? []) }
                }
                return false
            }
            for p in pending {
                var mine = Set<Int>()
                for ref in p.input.prereqs {
                    guard let pre = result.topicIds[ref] ?? result.topicIds[Self.topicKey(ref)], pre != p.id else { continue }
                    if reaches(pre, p.id) { result.warnings.append("Dropped a prerequisite loop around \"\(p.input.title)\"."); continue }
                    mine.insert(pre)
                    edges[p.id, default: []].insert(pre)
                }
                try db.execute("UPDATE path_topics SET prereq_ids_json = ? WHERE id = ?", [JSON.string(mine.sorted()), p.id])
            }

            // Where the course teaches each topic.
            let usable = Dictionary(uniqueKeysWithValues: materials(courseId: courseId)
                .filter { !$0.excluded && $0.status == "ready" && [.lecture, .reading, .example].contains($0.role) }.map { ($0.id, $0) })
            for p in pending where !p.input.sources.isEmpty {
                try db.execute("DELETE FROM topic_coverage WHERE topic_id = ? AND source = 'builder'", [p.id])
                for s in p.input.sources {
                    guard usable[s.materialId] != nil else {
                        result.warnings.append("\"\(p.input.title)\": file \(s.materialId) isn't a lecture, reading or example of this course.")
                        continue
                    }
                    let valid = Set(chunks(materialId: s.materialId).map(\.id))
                    let ids = s.chunkIds.filter(valid.contains)
                    try db.execute("""
                        INSERT INTO topic_coverage(topic_id, material_id, chunk_ids_json, source) VALUES(?,?,?,'builder')
                        ON CONFLICT(topic_id, material_id) DO UPDATE SET chunk_ids_json = excluded.chunk_ids_json, source = 'builder'
                        """, [p.id, s.materialId, JSON.string(ids)])
                }
            }

            // What each deadline or exam covers.
            let assignments = Set(self.assignments(AssignmentFilter(courseId: courseId, includeProposed: true)).map(\.id))
            for a in input.assessments {
                guard assignments.contains(a.assignmentId) else { result.warnings.append("Assignment \(a.assignmentId) isn't in this course."); continue }
                try db.execute("DELETE FROM assessment_topics WHERE assignment_id = ? AND source = 'builder'", [a.assignmentId])
                for ref in a.topics {
                    guard let id = result.topicIds[ref] ?? result.topicIds[Self.topicKey(ref)] else { continue }
                    try db.execute("INSERT OR IGNORE INTO assessment_topics(assignment_id, topic_id, source) VALUES(?,?,'builder')", [a.assignmentId, id])
                }
            }
            audit("save_path", entity: "course", id: courseId, detail: "\(tier): \(result.created) new, \(result.updated) kept, \(result.retired) retired")
        }
        return result
    }

    /// The student has done something with this topic, so a rebuilt path must not lose it.
    func topicHasProgress(_ t: PathTopic) -> Bool {
        if t.mastery != .new || t.notebookWrittenAt != nil || t.userState != nil { return true }
        let n = (try? db.scalarInt("""
            SELECT (SELECT count(*) FROM cards WHERE topic_id = ?) + (SELECT count(*) FROM study_sessions WHERE topic_id = ?)
                 + (SELECT count(*) FROM topic_checks WHERE topic_id = ?)
                 + (SELECT count(*) FROM practice_attempts a JOIN practice_items p ON p.id = a.item_id WHERE p.topic_id = ?)
            """, [t.id, t.id, t.id, t.id])) ?? 0
        return n > 0
    }

    // MARK: The student's choices

    /// `known` (skip it, I know this), `hidden`, or nil to bring it back.
    func setTopicUserState(_ id: Int, _ state: String?) throws {
        guard state == nil || state == "known" || state == "hidden" else { throw StoreError.invalid("Unknown topic state.") }
        try db.execute("UPDATE path_topics SET user_state = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?", [state, id])
        audit("topic_\(state ?? "restored")", entity: "topic", id: id)
    }

    /// The student wrote this topic's page in their notebook (and on which page), or took it back.
    func setNotebookWritten(_ id: Int, written: Bool, page: String? = nil, now: Date = Date()) throws {
        try db.execute("""
            UPDATE path_topics SET notebook_written_at = CASE WHEN ? THEN COALESCE(notebook_written_at, ?) ELSE NULL END,
              notebook_page = CASE WHEN ? THEN COALESCE(?, notebook_page) ELSE NULL END,
              updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, [written, ISO.instant(now), written, page?.nilIfEmpty.map { String($0.prefix(20)) }, id])
        refreshMastery(topicId: id, now: now)
    }

    // MARK: Notebook guide

    struct NotebookInput {
        public var topicId: Int?
        public var key: String?
        public var terms: [NotebookTerm]
        public var diagrams: [NotebookDiagram]
        public var formulas: [NotebookFormula]
        public var links: [String]
        public init(topicId: Int? = nil, key: String? = nil, terms: [NotebookTerm], diagrams: [NotebookDiagram] = [], formulas: [NotebookFormula] = [],
                    links: [String] = []) {
            self.topicId = topicId; self.key = key; self.terms = terms; self.diagrams = diagrams; self.formulas = formulas; self.links = links
        }
    }

    /// The course really words it this way: most of the wording's words are in the slides it cites, those slides are
    /// about the term, and it's a statement (a nearby question like "When does it occur?" isn't a definition).
    static func wordingMatches(_ wording: String, term: String, chunks: [Chunk]) -> Bool {
        let words = TopicLinker.words(wording)
        guard !words.isEmpty, !wording.contains("?") else { return false }
        let source = TopicLinker.words(chunks.map { [$0.heading ?? "", $0.textMd, $0.notesMd ?? ""].joined(separator: " ") }.joined(separator: " "))
        let found = Double(words.intersection(source).count) / Double(words.count)
        let termWords = TopicLinker.words(term)
        return found >= 0.5 && (termWords.isEmpty || !termWords.isDisjoint(with: source))
    }

    /// Chunks of this course's usable files, for checking what the course "says" against its own files.
    func courseChunkIds(courseId: Int) -> Set<Int> {
        Set(((try? db.query("""
            SELECT c.id FROM chunks c JOIN materials m ON m.id = c.material_id WHERE m.course_id = ? AND m.excluded = 0
            """, [courseId])) ?? []).map { $0.i("id") })
    }

    /// Saves notebook pages (at most 12 topics per call). A definition in the course's own words must cite the course's
    /// files; without valid citations it's kept as general knowledge instead. Drawings are sanitised; one that can't be
    /// made safe leaves just what to draw. The student's own marks (written, page number) never change.
    func saveNotebook(courseId: Int, _ entries: [NotebookInput], tier: String, generatedBy: String) throws -> WriteResult {
        guard entries.count <= 12 else { throw StoreError.invalid("At most 12 topics per call.") }
        guard Self.tierRank[tier] != nil else { throw StoreError.invalid("tier must be skeleton, basic or full.") }
        let topics = self.topics(courseId: courseId)
        let byId = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
        let byKey = Dictionary(topics.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let cited = courseChunkIds(courseId: courseId)
        var r = WriteResult()
        try db.transaction {
            for e in entries {
                guard let t = e.topicId.flatMap({ byId[$0] }) ?? e.key.flatMap({ byKey[Self.topicKey($0)] }) else {
                    r.skipped.append((e.key ?? e.topicId.map(String.init) ?? "?", "not a topic in this course's path")); continue
                }
                if let old = notebook(topicId: t.id), (Self.tierRank[old.tier] ?? 0) > (Self.tierRank[tier] ?? 0) {
                    r.skipped.append((t.title, "already has a fuller notebook page")); continue
                }
                var terms: [NotebookTerm] = []
                for var term in e.terms.prefix(8) {
                    term.term = String(term.term.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                    term.definition = String(TextRepair.markdown(term.definition).trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
                    guard !term.term.isEmpty else { continue }
                    term.sourceChunkIds = term.sourceChunkIds.filter(cited.contains)
                    if let raw = term.courseWording?.nilIfEmpty {
                        // "[chunk 812 · slide 4] …" markers copied from the prompt aren't part of the wording.
                        let w = raw.replacingOccurrences(of: #"^\s*\[chunk[^\]]*\]\s*"#, with: "", options: .regularExpression)
                        if term.sourceChunkIds.isEmpty {
                            term.courseWording = nil
                            r.warnings.append("\(t.title): \"\(term.term)\" in the course's words had no valid source, so it's kept as general knowledge.")
                        } else if !Self.wordingMatches(w, term: term.term, chunks: chunks(ids: term.sourceChunkIds)) {
                            term.courseWording = nil
                            r.warnings.append("\(t.title): the course's wording for \"\(term.term)\" isn't in the slides it cites, so it's kept as general knowledge.")
                        } else { term.courseWording = String(w.prefix(400)) }
                    } else { term.courseWording = nil }
                    if !term.sourceChunkIds.isEmpty { term.locator = chunks(ids: Array(term.sourceChunkIds.prefix(3))).map(\.locator).joined(separator: ", ") }
                    if term.definition.isEmpty && term.courseWording == nil && tier != "skeleton" { continue }
                    terms.append(term)
                }
                guard !terms.isEmpty || tier == "skeleton" else { r.skipped.append((t.title, "no words to write")); continue }
                var diagrams: [NotebookDiagram] = []
                for var d in e.diagrams.prefix(3) {
                    d.title = String(d.title.prefix(120)); d.draw = String(d.draw.prefix(400))
                    d.labels = Array(d.labels.prefix(12)).map { String($0.prefix(60)) }
                    if let svg = d.svg?.nilIfEmpty {
                        d.svg = SVGSanitizer.sanitize(svg)
                        if d.svg == nil { r.warnings.append("\(t.title): the drawing for \"\(d.title)\" wasn't safe to show, so only what to draw is kept.") }
                    } else { d.svg = nil }
                    guard !d.title.isEmpty || !d.draw.isEmpty else { continue }
                    diagrams.append(d)
                }
                let formulas = e.formulas.prefix(6).compactMap { f -> NotebookFormula? in
                    let latex = TextRepair.latex(f.latex.trimmingCharacters(in: CharacterSet(charactersIn: "$ "))).trimmingCharacters(in: CharacterSet(charactersIn: "$ "))
                    return latex.isEmpty ? nil : NotebookFormula(latex: String(latex.prefix(300)), meaning: String(TextRepair.markdown(f.meaning).prefix(300)))
                }
                let links = Array(e.links.prefix(6)).map { String($0.prefix(120)) }
                let existed = notebook(topicId: t.id) != nil
                try db.execute("""
                    INSERT INTO topic_notebook(topic_id, terms_json, diagrams_json, formulas_json, links_json, tier, generated_by)
                    VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(topic_id) DO UPDATE SET terms_json = excluded.terms_json, diagrams_json = excluded.diagrams_json,
                      formulas_json = excluded.formulas_json, links_json = excluded.links_json, tier = excluded.tier,
                      generated_by = excluded.generated_by, stale = 0, version = version + 1, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                    """, [t.id, JSON.encode(terms), JSON.encode(diagrams), JSON.encode(Array(formulas)), JSON.string(links), tier, generatedBy])
                if existed { r.updated += 1 } else { r.created += 1 }
                r.ids.append(t.id)
            }
            audit("save_notebook", entity: "course", id: courseId, detail: "\(r.created + r.updated) pages")
        }
        return r
    }

    // MARK: Lessons

    struct LessonInput {
        public var topicId: Int?
        public var key: String?
        public var preQuestion: String?
        public var sections: [LessonSection]
        public var checks: [CheckQuestion]
        public var cards: [LessonCard]
        public var explainPrompt: String?
        public var estMinutes: Int?
        public init(topicId: Int? = nil, key: String? = nil, preQuestion: String? = nil, sections: [LessonSection], checks: [CheckQuestion] = [],
                    cards: [LessonCard] = [], explainPrompt: String? = nil, estMinutes: Int? = nil) {
            self.topicId = topicId; self.key = key; self.preQuestion = preQuestion; self.sections = sections; self.checks = checks
            self.cards = cards; self.explainPrompt = explainPrompt; self.estMinutes = estMinutes
        }
    }

    /// Saves lessons (at most 5 per call). The course's-angle section must cite the course's own files; without valid
    /// citations it's left out, since it would claim something about the course nobody checked.
    func saveLessons(courseId: Int, _ entries: [LessonInput], tier: String, generatedBy: String) throws -> WriteResult {
        guard entries.count <= 5 else { throw StoreError.invalid("At most 5 lessons per call.") }
        guard Self.tierRank[tier] != nil else { throw StoreError.invalid("tier must be skeleton, basic or full.") }
        let topics = self.topics(courseId: courseId)
        let byId = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
        let byKey = Dictionary(topics.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let cited = courseChunkIds(courseId: courseId)
        var r = WriteResult()
        try db.transaction {
            for e in entries {
                guard let t = e.topicId.flatMap({ byId[$0] }) ?? e.key.flatMap({ byKey[Self.topicKey($0)] }) else {
                    r.skipped.append((e.key ?? e.topicId.map(String.init) ?? "?", "not a topic in this course's path")); continue
                }
                if let old = lesson(topicId: t.id), (Self.tierRank[old.tier] ?? 0) > (Self.tierRank[tier] ?? 0) {
                    r.skipped.append((t.title, "already has a fuller lesson")); continue
                }
                var sections: [LessonSection] = []
                var total = 0
                for var s in e.sections.prefix(8) {
                    guard LessonSection.kinds.contains(s.kind) else { continue }
                    s.title = String(s.title.prefix(120))
                    s.bodyMd = String(TextRepair.markdown(s.bodyMd).trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
                    s.sourceChunkIds = s.sourceChunkIds.filter(cited.contains)
                    guard !s.bodyMd.isEmpty, total + s.bodyMd.count <= 24_000 else { continue }
                    if s.kind == "course_angle" && s.sourceChunkIds.isEmpty {
                        r.warnings.append("\(t.title): the course's angle had no valid source in the course's files, so it was left out.")
                        continue
                    }
                    total += s.bodyMd.count
                    sections.append(s)
                }
                guard sections.contains(where: { $0.kind == "idea" }) else { r.skipped.append((t.title, "a lesson needs the idea")); continue }
                let checks = e.checks.prefix(5).map { CheckQuestion(prompt: String(TextRepair.markdown($0.prompt).prefix(300)), answer: String(TextRepair.markdown($0.answer).prefix(600))) }
                    .filter { !$0.prompt.isEmpty && !$0.answer.isEmpty }
                let cards = e.cards.prefix(8).map { LessonCard(front: String(TextRepair.markdown($0.front).prefix(200)), back: String(TextRepair.markdown($0.back).prefix(300))) }
                    .filter { !$0.front.isEmpty && !$0.back.isEmpty }
                let existed = lesson(topicId: t.id) != nil
                try db.execute("""
                    INSERT INTO topic_lessons(topic_id, tier, pre_question, sections_json, checks_json, cards_json, explain_prompt, est_minutes, generated_by)
                    VALUES(?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(topic_id) DO UPDATE SET tier = excluded.tier, pre_question = excluded.pre_question,
                      sections_json = excluded.sections_json, checks_json = excluded.checks_json, cards_json = excluded.cards_json,
                      explain_prompt = excluded.explain_prompt, est_minutes = excluded.est_minutes, generated_by = excluded.generated_by,
                      stale = 0, version = version + 1, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                    """, [t.id, tier, e.preQuestion.map { String($0.prefix(300)) }, JSON.encode(sections), JSON.encode(Array(checks)),
                          JSON.encode(Array(cards)), e.explainPrompt.map { String($0.prefix(300)) }, e.estMinutes.map { min(120, max(5, $0)) },
                          generatedBy])
                if existed { r.updated += 1 } else { r.created += 1 }
                r.ids.append(t.id)
            }
            audit("save_lessons", entity: "course", id: courseId, detail: "\(r.created + r.updated) lessons")
        }
        return r
    }
}
