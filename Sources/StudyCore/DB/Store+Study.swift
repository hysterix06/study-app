import Foundation

/// Errors written for Claude to act on (§8.1). The MCP layer turns these into `isError` results.
public struct ToolError: Error, CustomStringConvertible, Equatable {
    public var code: String
    public var message: String
    public var hint: String?
    public init(_ code: String, _ message: String, hint: String? = nil) { self.code = code; self.message = message; self.hint = hint }
    public var description: String { message }
    public static func invalid(_ m: String, hint: String? = nil) -> ToolError { ToolError("INVALID_ARGUMENT", m, hint: hint) }
    public static func notFound(_ m: String, hint: String? = nil) -> ToolError { ToolError("NOT_FOUND", m, hint: hint) }
    public static func reference(_ m: String, hint: String? = nil) -> ToolError { ToolError("INVALID_REFERENCE", m, hint: hint) }
}

public struct WriteResult {
    public var created = 0
    public var updated = 0
    public var skipped: [(key: String, reason: String)] = []
    public var ids: [Int] = []
    public var warnings: [String] = []
    public init() {}
    public var json: [String: Any] {
        var d: [String: Any] = ["created": created, "updated": updated, "skipped": skipped.map { ["key": $0.key, "reason": $0.reason] }]
        if !ids.isEmpty { d["ids"] = ids }
        if !warnings.isEmpty { d["warnings"] = warnings }
        return d
    }
}

public extension StudyStore {
    // MARK: Concepts

    func concepts(courseId: Int? = nil, materialId: Int? = nil) -> [Concept] {
        if let materialId {
            return ((try? db.query("""
                SELECT DISTINCT c.* FROM concepts c
                LEFT JOIN concept_sources s ON s.concept_id = c.id
                WHERE s.material_id = ? OR c.first_material_id = ?
                ORDER BY c.importance, c.name
                """, [materialId, materialId])) ?? []).map(Concept.init)
        }
        if let courseId {
            return ((try? db.query("SELECT * FROM concepts WHERE course_id = ? ORDER BY importance, name", [courseId])) ?? []).map(Concept.init)
        }
        return ((try? db.query("SELECT * FROM concepts ORDER BY course_id, importance, name")) ?? []).map(Concept.init)
    }

    func conceptSources(_ conceptId: Int) -> [(chunkId: Int, materialId: Int, locator: String, materialTitle: String)] {
        let rows = (try? db.query("""
            SELECT s.chunk_id, s.material_id, ch.locator, m.title FROM concept_sources s
            JOIN chunks ch ON ch.id = s.chunk_id JOIN materials m ON m.id = s.material_id
            WHERE s.concept_id = ? ORDER BY m.id, ch.ordinal
            """, [conceptId])) ?? []
        return rows.map { ($0.i("chunk_id"), $0.i("material_id"), $0.str("locator"), $0.str("title")) }
    }

    func conceptLinks(courseId: Int) -> [(from: Int, to: Int, relation: String)] {
        let rows = (try? db.query("""
            SELECT l.from_concept_id, l.to_concept_id, l.relation FROM concept_links l
            JOIN concepts c ON c.id = l.from_concept_id WHERE c.course_id = ?
            """, [courseId])) ?? []
        return rows.map { ($0.i("from_concept_id"), $0.i("to_concept_id"), $0.str("relation")) }
    }

    func saveUserConcept(courseId: Int, name: String, definition: String, importance: Int) throws {
        try db.execute("""
            INSERT INTO concepts(course_id, name, definition, importance, created_by) VALUES(?,?,?,?,'user')
            ON CONFLICT(course_id, name) DO UPDATE SET definition = excluded.definition, importance = excluded.importance,
              created_by = 'user', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            """, [courseId, name, definition, importance])
    }

    func deleteConcept(_ id: Int) throws { try db.execute("DELETE FROM concepts WHERE id = ?", [id]) }

    /// Validates that every chunk belongs to the material (§8.4 rule 8) and returns their locators.
    func validateChunks(_ ids: [Int], materialId: Int, field: String = "source_chunk_ids") throws -> [String] {
        guard !ids.isEmpty else { throw ToolError.invalid("\(field) must not be empty.", hint: "Cite at least one chunk id from get_chunks.") }
        let rows = try db.query("SELECT id, locator FROM chunks WHERE material_id = ? AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                                [materialId] + ids.map { $0 as Any? })
        let found = Dictionary(uniqueKeysWithValues: rows.map { ($0.i("id"), $0.str("locator")) })
        if let bad = ids.first(where: { found[$0] == nil }) {
            throw ToolError.reference("Chunk \(bad) does not belong to material \(materialId).",
                                      hint: "Call get_material(\(materialId)) to list valid chunk ids.")
        }
        return ids.compactMap { found[$0] }
    }

    func requireMaterialWithCourse(_ id: Int) throws -> (Material, Int) {
        guard let m = material(id) else { throw ToolError.notFound("Material \(id) does not exist.", hint: "Call list_materials to find valid ids.") }
        guard let c = m.courseId else {
            throw ToolError("PRECONDITION", "Material \(id) is not filed under a course yet.", hint: "Ask the student to confirm its course in the Study Tracker Inbox.")
        }
        return (m, c)
    }

    struct ConceptInput {
        public var name: String; public var definition: String; public var importance: Int; public var sourceChunkIds: [Int]
        public var links: [(toName: String, relation: String)]
        public init(name: String, definition: String, importance: Int, sourceChunkIds: [Int], links: [(toName: String, relation: String)] = []) {
            self.name = name; self.definition = definition; self.importance = importance; self.sourceChunkIds = sourceChunkIds; self.links = links
        }
    }

    /// Claude-authored concepts, upserted per course; never overwrites user-authored rows.
    func saveConcepts(materialId: Int, _ items: [ConceptInput]) throws -> WriteResult {
        let (_, courseId) = try requireMaterialWithCourse(materialId)
        if items.count > 30 { throw ToolError("TOO_LARGE", "At most 30 concepts per call (got \(items.count)).", hint: "Split into several calls.") }
        for c in items {
            let name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.count > 80 { throw ToolError.invalid("Concept name must be 1–80 characters: \"\(name.prefix(90))\".") }
            if c.definition.isEmpty || c.definition.count > 400 { throw ToolError.invalid("Definition of \"\(name)\" must be 1–400 characters.") }
            if !(1...3).contains(c.importance) { throw ToolError.invalid("importance must be 1, 2 or 3 for \"\(name)\".") }
            _ = try validateChunks(c.sourceChunkIds, materialId: materialId)
        }
        let relations = Set(["part_of", "causes", "contrasts", "example_of", "prerequisite"])
        var result = WriteResult()
        try db.transaction {
            var idsByName: [String: Int] = [:]
            for c in items {
                let name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let existing = try db.first("SELECT id, created_by FROM concepts WHERE course_id = ? AND name = ? COLLATE NOCASE", [courseId, name]) {
                    let id = existing.i("id")
                    if existing.str("created_by") == "user" {
                        result.skipped.append((name, "A concept the student wrote has this name; it was left unchanged."))
                    } else {
                        try db.execute("UPDATE concepts SET definition = ?, importance = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
                                       [c.definition, c.importance, id])
                        result.updated += 1
                    }
                    for ch in c.sourceChunkIds {
                        try db.execute("INSERT OR IGNORE INTO concept_sources(concept_id, material_id, chunk_id) VALUES(?,?,?)", [id, materialId, ch])
                    }
                    idsByName[name.lowercased()] = id
                    result.ids.append(id)
                } else {
                    let id = try db.execute("INSERT INTO concepts(course_id, first_material_id, name, definition, importance, created_by) VALUES(?,?,?,?,?,'claude')",
                                            [courseId, materialId, name, c.definition, c.importance]).lastInsertId
                    for ch in c.sourceChunkIds {
                        try db.execute("INSERT OR IGNORE INTO concept_sources(concept_id, material_id, chunk_id) VALUES(?,?,?)", [id, materialId, ch])
                    }
                    idsByName[name.lowercased()] = id
                    result.ids.append(id)
                    result.created += 1
                }
            }
            for c in items {
                guard let from = idsByName[c.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] else { continue }
                for l in c.links {
                    guard relations.contains(l.relation) else { result.skipped.append(("\(c.name) → \(l.toName)", "Unknown relation \(l.relation).")); continue }
                    let toId = try idsByName[l.toName.lowercased()]
                        ?? db.first("SELECT id FROM concepts WHERE course_id = ? AND name = ? COLLATE NOCASE", [courseId, l.toName])?.int("id")
                    guard let toId, toId != from else { result.skipped.append(("\(c.name) → \(l.toName)", "Linked concept not found in this course.")); continue }
                    try db.execute("INSERT OR IGNORE INTO concept_links(from_concept_id, to_concept_id, relation) VALUES(?,?,?)", [from, toId, l.relation])
                }
            }
            audit("save_concepts", entity: "material", id: materialId, detail: ["created": result.created, "updated": result.updated])
        }
        return result
    }

    // MARK: Questions

    func questions(materialId: Int? = nil, conceptId: Int? = nil, courseId: Int? = nil, kind: String? = nil) -> [Question] {
        var sql = "SELECT * FROM questions WHERE 1=1"
        var params: [Any?] = []
        if let materialId { sql += " AND material_id = ?"; params.append(materialId) }
        if let conceptId { sql += " AND concept_id = ?"; params.append(conceptId) }
        if let courseId { sql += " AND course_id = ?"; params.append(courseId) }
        if let kind { sql += " AND kind = ?"; params.append(kind) }
        sql += " ORDER BY material_id, id"
        return ((try? db.query(sql, params)) ?? []).map(Question.init)
    }

    struct QuestionInput {
        public var kind: String; public var prompt: String; public var answerKey: String; public var conceptName: String?
        public var sourceChunkIds: [Int]; public var difficulty: Int
        public init(kind: String, prompt: String, answerKey: String, conceptName: String? = nil, sourceChunkIds: [Int], difficulty: Int = 2) {
            self.kind = kind; self.prompt = prompt; self.answerKey = answerKey; self.conceptName = conceptName
            self.sourceChunkIds = sourceChunkIds; self.difficulty = difficulty
        }
    }

    func saveQuestions(materialId: Int, _ items: [QuestionInput], createCards: Bool, createdBy: String = "claude") throws -> WriteResult {
        let (_, courseId) = try requireMaterialWithCourse(materialId)
        if items.count > 40 { throw ToolError("TOO_LARGE", "At most 40 questions per call (got \(items.count)).", hint: "Split into several calls.") }
        let kinds = Set(["recall", "explain", "apply", "compare", "calculate"])
        var locators: [[String]] = []
        for q in items {
            if !kinds.contains(q.kind) { throw ToolError.invalid("Question kind must be recall, explain, apply, compare or calculate (got \(q.kind)).") }
            if q.prompt.isEmpty || q.prompt.count > 400 { throw ToolError.invalid("Question prompt must be 1–400 characters.") }
            if q.answerKey.isEmpty || q.answerKey.count > 800 { throw ToolError.invalid("answer_key must be 1–800 characters.") }
            if !(1...3).contains(q.difficulty) { throw ToolError.invalid("difficulty must be 1, 2 or 3.") }
            locators.append(try validateChunks(q.sourceChunkIds, materialId: materialId))
        }
        var result = WriteResult()
        try db.transaction {
            let existing = Set(try db.query("SELECT prompt FROM questions WHERE material_id = ?", [materialId])
                .map { $0.str("prompt").lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
            var seen = existing
            for (i, q) in items.enumerated() {
                let key = q.prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if seen.contains(key) { result.skipped.append((String(q.prompt.prefix(60)), "Duplicate prompt for this material.")); continue }
                seen.insert(key)
                let conceptId = try q.conceptName.flatMap { try db.first("SELECT id FROM concepts WHERE course_id = ? AND name = ? COLLATE NOCASE", [courseId, $0])?.int("id") }
                let id = try db.execute("""
                    INSERT INTO questions(course_id, material_id, concept_id, kind, prompt, answer_key, source_chunk_ids, difficulty, created_by)
                    VALUES(?,?,?,?,?,?,?,?,?)
                    """, [courseId, materialId, conceptId, q.kind, q.prompt, q.answerKey, JSON.string(q.sourceChunkIds), q.difficulty, createdBy]).lastInsertId
                result.ids.append(id)
                result.created += 1
                if createCards {
                    try insertCard(courseId: courseId, materialId: materialId, conceptId: conceptId, questionId: id, front: q.prompt,
                                   back: q.answerKey, locators: locators[i].joined(separator: ", "),
                                   status: createdBy == "claude" ? "proposed" : "active", createdBy: createdBy)
                }
            }
            audit("save_questions", entity: "material", id: materialId, detail: ["created": result.created, "cards": createCards])
        }
        return result
    }

    // MARK: Cards

    @discardableResult
    func insertCard(courseId: Int, materialId: Int?, conceptId: Int?, questionId: Int?, front: String, back: String, locators: String?,
                    status: String, createdBy: String, now: Date = Date()) throws -> Int {
        try db.execute("""
            INSERT INTO cards(course_id, material_id, concept_id, question_id, front, back, source_locators, due, state, fsrs_json, status, created_by)
            VALUES(?,?,?,?,?,?,?,?,0,?,?,?)
            """, [courseId, materialId, conceptId, questionId, front, back, locators, ISO.instant(now), FSRSCard().encode(), status, createdBy]).lastInsertId
    }

    struct CardInput {
        public var front: String; public var back: String; public var conceptName: String?; public var sourceChunkIds: [Int]
        public init(front: String, back: String, conceptName: String? = nil, sourceChunkIds: [Int]) {
            self.front = front; self.back = back; self.conceptName = conceptName; self.sourceChunkIds = sourceChunkIds
        }
    }

    /// Claude proposes; the student approves or rewrites in the app (cards they write themselves stick better).
    func proposeCards(materialId: Int, _ items: [CardInput]) throws -> WriteResult {
        let (_, courseId) = try requireMaterialWithCourse(materialId)
        if items.count > 40 { throw ToolError("TOO_LARGE", "At most 40 cards per call.") }
        var locs: [[String]] = []
        for c in items {
            if c.front.isEmpty || c.front.count > 200 { throw ToolError.invalid("Card front must be 1–200 characters.", hint: "One small idea per card.") }
            if c.back.isEmpty || c.back.count > 300 { throw ToolError.invalid("Card back must be 1–300 characters.", hint: "Keep answers short; split big ideas into several cards.") }
            locs.append(try validateChunks(c.sourceChunkIds, materialId: materialId))
        }
        var result = WriteResult()
        try db.transaction {
            let existing = Set(try db.query("SELECT front FROM cards WHERE course_id = ?", [courseId]).map { $0.str("front").lowercased() })
            for (i, c) in items.enumerated() {
                if existing.contains(c.front.lowercased()) { result.skipped.append((String(c.front.prefix(60)), "A card with this front already exists.")); continue }
                let conceptId = try c.conceptName.flatMap { try db.first("SELECT id FROM concepts WHERE course_id = ? AND name = ? COLLATE NOCASE", [courseId, $0])?.int("id") }
                let id = try insertCard(courseId: courseId, materialId: materialId, conceptId: conceptId, questionId: nil, front: c.front,
                                        back: c.back, locators: locs[i].joined(separator: ", "), status: "proposed", createdBy: "claude")
                result.ids.append(id); result.created += 1
            }
            audit("propose_cards", entity: "material", id: materialId, detail: ["created": result.created])
        }
        return result
    }

    func cards(courseId: Int? = nil, status: String? = "active", materialId: Int? = nil) -> [Card] {
        var sql = "SELECT * FROM cards WHERE 1=1"
        var params: [Any?] = []
        if let status { sql += " AND status = ?"; params.append(status) }
        if let courseId { sql += " AND course_id = ?"; params.append(courseId) }
        if let materialId { sql += " AND material_id = ?"; params.append(materialId) }
        sql += " ORDER BY due, id"
        return ((try? db.query(sql, params)) ?? []).map(Card.init)
    }

    func card(_ id: Int) -> Card? { (try? db.first("SELECT * FROM cards WHERE id = ?", [id])).map(Card.init) }

    /// Due cards, interleaved across courses and materials (§9.1 interleaving).
    func reviewQueue(courseId: Int? = nil, limit: Int = 20, now: Date = Date()) -> [Card] {
        var sql = "SELECT * FROM cards WHERE status = 'active' AND due <= ?"
        var params: [Any?] = [ISO.instant(now)]
        if let courseId { sql += " AND course_id = ?"; params.append(courseId) }
        sql += " ORDER BY due LIMIT ?"
        params.append(max(limit * 3, limit))
        let due = ((try? db.query(sql, params)) ?? []).map(Card.init)
        // Round-robin by material so consecutive cards come from different lectures.
        var buckets = Dictionary(grouping: due, by: { $0.materialId ?? -$0.courseId })
        var order = buckets.keys.sorted { (buckets[$0]!.first!.due) < (buckets[$1]!.first!.due) }
        var out: [Card] = []
        while out.count < limit && !order.isEmpty {
            var next: [Int] = []
            for k in order {
                guard out.count < limit else { break }
                if var list = buckets[k], !list.isEmpty {
                    out.append(list.removeFirst()); buckets[k] = list
                    if !list.isEmpty { next.append(k) }
                }
            }
            order = next
        }
        return out
    }

    func dueCount(now: Date = Date()) -> Int {
        (try? db.scalarInt("SELECT count(*) FROM cards WHERE status = 'active' AND due <= ?", [ISO.instant(now)])) ?? 0
    }

    func proposedCardCount() -> Int { (try? db.scalarInt("SELECT count(*) FROM cards WHERE status = 'proposed'")) ?? 0 }

    func saveCard(id: Int, front: String, back: String, status: String) throws {
        try db.execute("UPDATE cards SET front = ?, back = ?, status = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
                       [front, back, status, id])
    }

    func deleteCard(_ id: Int) throws { try db.execute("DELETE FROM cards WHERE id = ?", [id]) }

    func addUserCard(courseId: Int, materialId: Int?, front: String, back: String) throws -> Int {
        try insertCard(courseId: courseId, materialId: materialId, conceptId: nil, questionId: nil, front: front, back: back,
                       locators: nil, status: "active", createdBy: "user")
    }

    func cardFromQuestion(_ q: Question) throws -> Int? {
        if try db.scalarInt("SELECT count(*) FROM cards WHERE question_id = ?", [q.id]) > 0 { return nil }
        let locs = chunks(ids: q.sourceChunkIds).map(\.locator).joined(separator: ", ")
        return try insertCard(courseId: q.courseId, materialId: q.materialId, conceptId: q.conceptId, questionId: q.id,
                              front: q.prompt, back: q.answerKey, locators: locs, status: "active", createdBy: "user")
    }

    /// Ratings always come from the student (§8.3 log_review).
    @discardableResult
    func logReview(cardId: Int, rating: Rating, now: Date = Date(), durationMs: Int? = nil, fsrs: FSRS = FSRS()) throws -> FSRSResult {
        guard let card = card(cardId) else { throw ToolError.notFound("Card \(cardId) does not exist.", hint: "Call get_review_queue for current card ids.") }
        guard card.status == "active" else {
            throw ToolError("PRECONDITION", "Card \(cardId) is \(card.status), not active.", hint: "Proposed cards must be approved by the student in the app first.")
        }
        let result = fsrs.review(card.fsrs, rating: rating, now: now)
        let elapsed = card.fsrs.lastReview.map { now.timeIntervalSince($0) / 86400 }
        try db.transaction {
            try db.execute("UPDATE cards SET due = ?, state = ?, fsrs_json = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
                           [ISO.instant(result.due), result.card.state.rawValue, result.card.encode(), cardId])
            try db.execute("INSERT INTO card_reviews(card_id, reviewed_at, rating, rated_by, state_before, elapsed_days, duration_ms) VALUES(?,?,?,'user',?,?,?)",
                           [cardId, ISO.instant(now), rating.rawValue, card.fsrs.state.rawValue, elapsed, durationMs])
            audit("log_review", entity: "card", id: cardId, detail: ["rating": rating.rawValue])
        }
        return result
    }

    // MARK: Notes

    func notes(courseId: Int? = nil, materialId: Int? = nil, kind: String? = nil) -> [Note] {
        var sql = "SELECT * FROM notes WHERE 1=1"
        var params: [Any?] = []
        if let courseId { sql += " AND course_id = ?"; params.append(courseId) }
        if let materialId { sql += " AND material_id = ?"; params.append(materialId) }
        if let kind { sql += " AND kind = ?"; params.append(kind) }
        sql += " ORDER BY updated_at DESC"
        return ((try? db.query(sql, params)) ?? []).map(Note.init)
    }

    func note(_ id: Int) -> Note? { (try? db.first("SELECT * FROM notes WHERE id = ?", [id])).map(Note.init) }

    func saveUserNote(courseId: Int, materialId: Int?, title: String, content: String, id: Int? = nil) throws -> Int {
        if let id {
            try db.execute("UPDATE notes SET title = ?, content_md = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ? AND created_by = 'user'",
                           [title, content, id])
            return id
        }
        return try db.execute("INSERT INTO notes(course_id, material_id, kind, title, content_md, created_by) VALUES(?,?,'user_note',?,?,'user')",
                              [courseId, materialId, title, content]).lastInsertId
    }

    func deleteNote(_ id: Int) throws { try db.execute("DELETE FROM notes WHERE id = ?", [id]) }

    /// Upsert on (material, kind, title) over Claude-authored rows only.
    func saveClaudeNote(courseId: Int, materialId: Int?, assignmentId: Int? = nil, kind: String, title: String, content: String, dataJson: String? = nil) throws -> WriteResult {
        var r = WriteResult()
        try db.transaction {
            let existing = try db.first("""
                SELECT id, created_by FROM notes WHERE course_id = ? AND COALESCE(material_id, 0) = COALESCE(?, 0) AND kind = ? AND title = ?
                ORDER BY created_by = 'claude' DESC LIMIT 1
                """, [courseId, materialId, kind, title])
            if let existing, existing.str("created_by") == "claude" {
                try db.execute("UPDATE notes SET content_md = ?, data_json = ?, assignment_id = COALESCE(?, assignment_id), updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
                               [content, dataJson, assignmentId, existing.i("id")])
                r.updated = 1; r.ids = [existing.i("id")]
            } else if existing != nil {
                r.skipped.append((title, "The student wrote a note with this title; it was left unchanged."))
            } else {
                let id = try db.execute("INSERT INTO notes(course_id, material_id, assignment_id, kind, title, content_md, data_json, created_by) VALUES(?,?,?,?,?,?,?,'claude')",
                                        [courseId, materialId, assignmentId, kind, title, content, dataJson]).lastInsertId
                r.created = 1; r.ids = [id]
            }
            audit("save_note", entity: "note", id: r.ids.first, detail: ["kind": kind, "title": title])
        }
        return r
    }

    // MARK: Sessions

    func sessions(courseId: Int? = nil, materialId: Int? = nil, limit: Int = 100) -> [StudySession] {
        var sql = "SELECT * FROM study_sessions WHERE 1=1"
        var params: [Any?] = []
        if let courseId { sql += " AND course_id = ?"; params.append(courseId) }
        if let materialId { sql += " AND material_id = ?"; params.append(materialId) }
        sql += " ORDER BY started_at DESC LIMIT ?"
        params.append(limit)
        return ((try? db.query(sql, params)) ?? []).map(StudySession.init)
    }

    func openSession() -> StudySession? {
        (try? db.first("SELECT * FROM study_sessions WHERE ended_at IS NULL ORDER BY started_at DESC LIMIT 1")).map(StudySession.init)
    }

    @discardableResult
    func startSession(kind: String, courseId: Int?, materialId: Int?, assignmentId: Int? = nil, now: Date = Date()) throws -> Int {
        try db.execute("INSERT INTO study_sessions(course_id, material_id, assignment_id, kind, started_at, created_by) VALUES(?,?,?,?,?,'user')",
                       [courseId, materialId, assignmentId, kind, ISO.instant(now)]).lastInsertId
    }

    func endSession(_ id: Int, summary: String?, total: Int? = nil, correct: Int? = nil, now: Date = Date()) throws {
        try db.execute("UPDATE study_sessions SET ended_at = ?, summary = COALESCE(?, summary), items_total = COALESCE(?, items_total), items_correct = COALESCE(?, items_correct) WHERE id = ?",
                       [ISO.instant(now), summary, total, correct, id])
    }

    func recordClaudeSession(kind: String, courseId: Int?, materialId: Int?, assignmentId: Int?, startedAt: Date?, summary: String,
                             weakConceptNames: [String], itemsTotal: Int?, itemsCorrect: Int?, now: Date = Date()) throws -> (id: Int, unmatched: [String]) {
        let kinds = Set(["process", "recall", "feynman", "quiz", "review", "handwriting"])
        guard kinds.contains(kind) else { throw ToolError.invalid("kind must be one of process, recall, feynman, quiz, review, handwriting.") }
        guard summary.count <= 1500, !summary.isEmpty else { throw ToolError.invalid("summary must be 1–1500 characters.") }
        var course = courseId
        if let materialId {
            guard let m = material(materialId) else { throw ToolError.notFound("Material \(materialId) does not exist.") }
            course = course ?? m.courseId
        }
        if let assignmentId {
            guard let a = assignment(assignmentId) else { throw ToolError.notFound("Assignment \(assignmentId) does not exist.") }
            course = course ?? a.courseId
        }
        if let c = course, self.course(c) == nil { throw ToolError.notFound("Course \(c) does not exist.") }
        var ids: [Int] = [], unmatched: [String] = []
        for name in weakConceptNames {
            var sql = "SELECT id FROM concepts WHERE name = ? COLLATE NOCASE"
            var params: [Any?] = [name]
            if let c = course { sql += " AND course_id = ?"; params.append(c) }
            if let id = try db.first(sql, params)?.int("id") { ids.append(id) } else { unmatched.append(name) }
        }
        let id = try db.execute("""
            INSERT INTO study_sessions(course_id, material_id, assignment_id, kind, started_at, ended_at, summary, weak_concept_ids, items_total, items_correct, created_by)
            VALUES(?,?,?,?,?,?,?,?,?,?,'claude')
            """, [course, materialId, assignmentId, kind, ISO.instant(startedAt ?? now), ISO.instant(now), summary, JSON.string(ids), itemsTotal, itemsCorrect]).lastInsertId
        audit("record_session", entity: "study_session", id: id, detail: ["kind": kind])
        return (id, unmatched)
    }

    /// Concepts flagged weak in sessions over the last `days`, most frequent first.
    func weakConcepts(courseId: Int? = nil, days: Int = 30, now: Date = Date()) -> [(concept: Concept, count: Int)] {
        let since = ISO.instant(now.adding(days: -Double(days)))
        var counts: [Int: Int] = [:]
        for s in sessions(courseId: courseId, limit: 500) where ISO.instant(s.startedAt) >= since {
            for id in s.weakConceptIds { counts[id, default: 0] += 1 }
        }
        let all = Dictionary(uniqueKeysWithValues: concepts().map { ($0.id, $0) })
        return counts.compactMap { k, v in all[k].map { ($0, v) } }.sorted { $0.1 > $1.1 }
    }
}
