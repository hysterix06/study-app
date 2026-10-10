import Foundation

/// A problem in the practice bank: from the course's own files (word for word) or written by the AI for a topic.
public struct PracticeItem: Identifiable, Hashable {
    public var id: Int
    public var courseId: Int
    public var topicId: Int?
    /// A short topic name from the AI's labels, used until the problem is linked to a path topic.
    public var topicLabel: String?
    /// `course` (from a course file) or `generated` (written by the AI, including old slide questions).
    public var source: String
    public var materialId: Int?
    public var chunkIds: [Int]
    public var locator: String?
    public var number: String?
    /// calculate, short, explain, apply, compare, mcq, essay, proof, case or other (not labelled yet).
    public var kind: String
    public var promptMd: String
    public var solutionMd: String?
    public var hints: [String]
    public var difficulty: Int
    public var examStyle: Bool
    public var marks: Double?
    public var createdBy: String

    init(row r: Row) {
        id = r.i("id"); courseId = r.i("course_id"); topicId = r.int("topic_id"); topicLabel = r.string("topic_label")
        source = r.str("source"); materialId = r.int("material_id"); chunkIds = JSON.intArray(r.string("chunk_ids_json"))
        locator = r.string("locator"); number = r.string("number"); kind = r.str("kind"); promptMd = r.str("prompt_md")
        solutionMd = r.string("solution_md"); hints = JSON.stringArray(r.string("hints_json")); difficulty = r.int("difficulty") ?? 2
        examStyle = r.bool("exam_style"); marks = r.double("marks"); createdBy = r.str("created_by")
    }

    public static let kinds = ["calculate", "short", "explain", "apply", "compare", "mcq", "essay", "proof", "case", "other"]

    /// Not labelled by the AI yet: the problem works, but its kind and topic are unknown.
    public var isUnlabelled: Bool { source == "course" && kind == "other" && topicLabel == nil }
}

public extension StudyStore {
    func practiceItems(courseId: Int? = nil, materialId: Int? = nil, topicId: Int? = nil) -> [PracticeItem] {
        var sql = "SELECT * FROM practice_items WHERE 1=1"
        var params: [Any?] = []
        if let courseId { sql += " AND course_id = ?"; params.append(courseId) }
        if let materialId { sql += " AND material_id = ?"; params.append(materialId) }
        if let topicId { sql += " AND topic_id = ?"; params.append(topicId) }
        return ((try? db.query(sql + " ORDER BY material_id, id", params)) ?? []).map(PracticeItem.init)
    }

    func practiceItem(_ id: Int) -> PracticeItem? { (try? db.first("SELECT * FROM practice_items WHERE id = ?", [id])).map(PracticeItem.init) }

    // MARK: From course files

    /// Splits a problem set, class example or past exam into its problems, word for word, and keeps them in the practice
    /// bank. A solutions file adds its answers to the sheet it pairs with instead of becoming problems itself. Runs
    /// without any AI. Problems the student already attempted are kept as they are. Returns the file's problem count.
    @discardableResult
    func splitPractice(materialId: Int) -> Int {
        guard let m = material(materialId), let courseId = m.courseId else { return 0 }
        guard [.practice, .example, .pastExam].contains(m.role), !m.excluded, m.status == "ready" else {
            removeUntriedPractice(materialId: materialId)
            return 0
        }
        if Self.isSolutionsFile(m), let sheet = m.pairsWith {
            removeUntriedPractice(materialId: materialId)
            setReadState(materialId, "done")
            return splitPractice(materialId: sheet)
        }
        var drafts = PracticeSplitter.split(chunks(materialId: materialId))
        if let answers = materials(courseId: courseId).first(where: { $0.pairsWith == materialId && !$0.excluded }) {
            drafts = PracticeSplitter.attachSolutions(drafts, from: PracticeSplitter.split(chunks(materialId: answers.id), answers: true))
        }
        let exam = m.role == .pastExam
        let labels = Dictionary(practiceItems(materialId: materialId).compactMap { i in i.number.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        _ = try? db.transaction {
            try db.execute("""
                DELETE FROM practice_items WHERE material_id = ? AND source = 'course'
                  AND NOT EXISTS (SELECT 1 FROM practice_attempts a WHERE a.item_id = practice_items.id)
                """, [materialId])
            let kept = Set(practiceItems(materialId: materialId).compactMap(\.number))
            for d in drafts where !kept.contains(d.number) {
                // A re-split keeps the AI's labels for the same problem number.
                let old = labels[d.number]
                try db.execute("""
                    INSERT INTO practice_items(course_id, topic_id, topic_label, source, material_id, chunk_ids_json, locator, number, kind,
                      prompt_md, solution_md, difficulty, exam_style, marks, created_by)
                    VALUES(?,?,?,'course',?,?,?,?,?,?,?,?,?,?,'app')
                    """, [courseId, old?.topicId, old?.topicLabel, materialId, JSON.string(d.chunkIds), d.locator, d.number, old?.kind ?? "other",
                          d.prompt, d.solution, old?.difficulty ?? 2, exam, d.marks])
            }
        }
        setReadState(materialId, "done")
        return practiceItems(materialId: materialId).count
    }

    /// When a file stops being practice: its problems go, except ones the student attempted.
    func removeUntriedPractice(materialId: Int) {
        _ = try? db.execute("""
            DELETE FROM practice_items WHERE material_id = ? AND source = 'course'
              AND NOT EXISTS (SELECT 1 FROM practice_attempts a WHERE a.item_id = practice_items.id)
            """, [materialId])
    }

    /// Practice, example and exam files whose problems haven't been split out yet.
    func filesToSplit() -> [Material] {
        ((try? db.query("""
            SELECT * FROM materials WHERE course_id IS NOT NULL AND excluded = 0 AND status = 'ready' AND read_state = 'pending'
              AND role IN ('practice','example','past_exam')
            """)) ?? []).map(Material.init)
    }

    /// Files with problems the AI hasn't labelled yet (kind, difficulty, topic).
    func filesWithUnlabelledPractice() -> [Material] {
        ((try? db.query("""
            SELECT DISTINCT m.* FROM materials m JOIN practice_items p ON p.material_id = m.id
            WHERE p.source = 'course' AND p.kind = 'other' AND p.topic_label IS NULL AND m.excluded = 0
            """)) ?? []).map(Material.init)
    }

    /// The AI's labels for problems split out of one file. The problem text and solutions never change.
    struct PracticeLabel {
        public var id: Int
        public var kind: String?
        public var difficulty: Int?
        public var topicLabel: String?
        public var marks: Double?
        public init(id: Int, kind: String?, difficulty: Int?, topicLabel: String?, marks: Double?) {
            self.id = id; self.kind = kind; self.difficulty = difficulty; self.topicLabel = topicLabel; self.marks = marks
        }
    }

    func labelPracticeItems(materialId: Int, _ labels: [PracticeLabel]) throws -> WriteResult {
        guard material(materialId) != nil else { throw StoreError.notFound("Material \(materialId) does not exist.") }
        let ids = Set(practiceItems(materialId: materialId).map(\.id))
        var result = WriteResult()
        try db.transaction {
            for l in labels {
                guard ids.contains(l.id) else { result.skipped.append(("\(l.id)", "not a problem from this file")); continue }
                let kind = l.kind.flatMap { PracticeItem.kinds.contains($0) ? $0 : nil }
                try db.execute("""
                    UPDATE practice_items SET kind = COALESCE(?, kind), difficulty = COALESCE(?, difficulty), topic_label = COALESCE(?, topic_label),
                      marks = COALESCE(marks, ?), updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
                    """, [kind, l.difficulty.map { min(3, max(1, $0)) }, l.topicLabel.map { String($0.prefix(80)) }, l.marks, l.id])
                result.updated += 1
            }
            audit("label_practice", entity: "material", id: materialId, detail: "\(result.updated) problems")
        }
        return result
    }

    /// New syllabi and briefs to read for deadlines and the weekly plan. Files that were already here when this version
    /// first ran are left alone, so deadlines the student already has don't come back as proposals.
    func syllabiToRead() -> [Material] {
        guard let since = setting("files_read_since") else { return [] }
        return ((try? db.query("""
            SELECT * FROM materials WHERE course_id IS NOT NULL AND excluded = 0 AND status = 'ready' AND read_state = 'pending'
              AND role IN ('syllabus','brief') AND imported_at >= ?
            """, [since])) ?? []).map(Material.init)
    }

    // MARK: Reading state and scans

    func setReadState(_ id: Int, _ state: String, engine: String? = nil) {
        _ = try? db.execute("UPDATE materials SET read_state = ?, read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), read_engine = COALESCE(?, read_engine) WHERE id = ?",
                            [state, engine, id])
    }

    /// What the free AI found in a file (a syllabus's outcomes and weekly plan, a lecture's topics), kept so the course
    /// builder can use it without reading the file again.
    func saveMaterialScan(materialId: Int, kind: String, json: String, engine: String?) throws {
        guard ["outline", "syllabus", "practice", "exam"].contains(kind) else { throw StoreError.invalid("Unknown scan kind \(kind).") }
        guard material(materialId) != nil else { throw StoreError.notFound("Material \(materialId) does not exist.") }
        try db.execute("""
            INSERT INTO material_scans(material_id, kind, result_json, engine) VALUES(?,?,?,?)
            ON CONFLICT(material_id, kind) DO UPDATE SET result_json = excluded.result_json, engine = excluded.engine,
              created_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            """, [materialId, kind, json, engine])
    }

    func materialScan(materialId: Int, kind: String) -> String? {
        (try? db.scalarString("SELECT result_json FROM material_scans WHERE material_id = ? AND kind = ?", [materialId, kind])) ?? nil
    }
}
