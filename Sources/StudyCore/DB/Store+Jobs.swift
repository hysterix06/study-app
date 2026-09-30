import Foundation

/// Claude is one feature (UI remap principle 6): every Claude task is a job with one label, one queue and one
/// Activity log, whichever way it runs.
///
/// - Automatic: the app runs Claude Code in the background. Queued → Running → Done or Failed.
/// - Claude Desktop: the app copies the prompt (carrying the job id) and opens Desktop. Handed off → Waiting → Done.
///   MCP writes tagged with the job id attach their results, and the task's final tool marks the job Done.
public enum ClaudeTask: String, CaseIterable, Codable {
    case process, extractDeadlines = "extract_deadlines", examPatterns = "exam_patterns", checkDraft = "check_draft"
    case reviewNotes = "review_notes", quiz, recall, explain, practice, weeklyPlan = "weekly_plan"

    /// One label per task; it never changes with run mode.
    public var label: String {
        switch self {
        case .process: return "Process with Claude"
        case .extractDeadlines: return "Extract deadlines with Claude"
        case .examPatterns: return "Find exam patterns with Claude"
        case .checkDraft: return "Check draft with Claude"
        case .reviewNotes: return "Review my notes with Claude"
        case .quiz: return "Quiz me with Claude"
        case .recall: return "Recall with Claude"
        case .explain: return "Explain it to Claude"
        case .practice: return "Practice problems with Claude"
        case .weeklyPlan: return "Plan my week with Claude"
        }
    }

    /// Short noun phrase for Activity rows: "Processing HM210 Week 4".
    public var activity: String {
        switch self {
        case .process: return "Processing"
        case .extractDeadlines: return "Extracting deadlines from"
        case .examPatterns: return "Finding exam patterns in"
        case .checkDraft: return "Checking the draft for"
        case .reviewNotes: return "Reviewing notes for"
        case .quiz: return "Quiz on"
        case .recall: return "Recall session for"
        case .explain: return "Explaining"
        case .practice: return "Practice problems from"
        case .weeklyPlan: return "Planning the week"
        }
    }

    public var prompt: String {
        switch self {
        case .process: return "process_lecture"
        case .extractDeadlines: return "extract_deadlines"
        case .examPatterns: return "exam_patterns"
        case .checkDraft: return "check_draft"
        case .reviewNotes: return "review_handwriting"
        case .quiz: return "quiz_me"
        case .recall: return "recall_first"
        case .explain: return "feynman_check"
        case .practice: return "practice_problems"
        case .weeklyPlan: return "weekly_plan"
        }
    }

    /// Tasks that talk with the student always run in Claude Desktop (decision D9).
    public var conversational: Bool {
        switch self {
        case .quiz, .recall, .explain, .checkDraft, .practice: return true
        default: return false
        }
    }

    /// The MCP write that finishes the task.
    public func isFinished(by tool: String, args: [String: Any]) -> Bool {
        switch self {
        case .process: return tool == "mark_material_processed"
        case .extractDeadlines: return tool == "propose_assignments"
        case .weeklyPlan: return tool == "propose_study_blocks"
        case .examPatterns: return tool == "save_note" && (args["kind"] as? String) == "exam_patterns"
        case .checkDraft: return tool == "save_note" && (args["kind"] as? String) == "rubric_check"
        case .reviewNotes, .quiz, .recall, .explain, .practice: return tool == "record_session"
        }
    }
}

public enum JobMode: String, Codable { case automatic, desktop }

public enum JobState: String, Codable, CaseIterable {
    case queued, running, handedOff = "handed_off", waiting, done, failed, canceled

    public var title: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .handedOff: return "Handed off"
        case .waiting: return "Waiting for Claude"
        case .done: return "Done"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }

    public var isActive: Bool { [.queued, .running, .handedOff, .waiting].contains(self) }
    /// Counted by the Activity badge: the job is waiting on the student.
    public var needsAttention: Bool { [.handedOff, .waiting, .failed].contains(self) }
}

public struct ClaudeJob: Identifiable, Hashable {
    public var id: Int
    public var task: ClaudeTask
    public var args: [String: String]
    public var objectKind: String?
    public var objectId: Int?
    public var label: String
    public var mode: JobMode
    public var state: JobState
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var resultSummary: String?
    /// Items written per tool, e.g. ["save_concepts": 14, "propose_cards": 22].
    public var results: [String: Int]
    public var error: String?

    init(row r: Row) {
        id = r.i("id")
        task = ClaudeTask(rawValue: r.str("task")) ?? .process
        args = (try? JSONDecoder().decode([String: String].self, from: Data(r.str("args_json").utf8))) ?? [:]
        objectKind = r.string("object_kind")
        objectId = r.int("object_id")
        label = r.str("label")
        mode = JobMode(rawValue: r.str("mode")) ?? .desktop
        state = JobState(rawValue: r.str("state")) ?? .failed
        createdAt = ISO.parse(r.str("created_at")) ?? Date()
        startedAt = r.string("started_at").flatMap { ISO.parse($0) }
        finishedAt = r.string("finished_at").flatMap { ISO.parse($0) }
        resultSummary = r.string("result_summary")
        results = (try? JSONDecoder().decode([String: Int].self, from: Data(r.str("results_json").utf8))) ?? [:]
        error = r.string("error")
    }

    /// "Added 14 concepts · 22 cards to approve".
    public static func summary(_ results: [String: Int]) -> String? {
        let nouns: [(String, String, String)] = [
            ("save_concepts", "concept", "concepts"), ("save_questions", "question", "questions"),
            ("propose_cards", "card to approve", "cards to approve"), ("propose_assignments", "deadline to confirm", "deadlines to confirm"),
            ("propose_study_blocks", "study block to review", "study blocks to review"), ("save_cornell_sheet", "sheet", "sheets"),
            ("save_note", "note", "notes"), ("record_session", "session", "sessions"),
        ]
        let parts = nouns.compactMap { tool, one, many -> String? in
            guard let n = results[tool], n > 0 else { return nil }
            return "\(n) \(n == 1 ? one : many)"
        }
        return parts.isEmpty ? nil : "Added " + parts.joined(separator: " · ")
    }
}

public extension StudyStore {
    @discardableResult
    func enqueueJob(_ task: ClaudeTask, args: [String: String], objectKind: String?, objectId: Int?, label: String, mode: JobMode) throws -> Int {
        let json = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        let id = try db.execute("INSERT INTO claude_jobs(task, args_json, object_kind, object_id, label, mode) VALUES(?,?,?,?,?,?)",
                                [task.rawValue, json, objectKind, objectId, label, mode.rawValue]).lastInsertId
        audit("job_queued", entity: "job", id: id, detail: label)
        return id
    }

    func job(_ id: Int) -> ClaudeJob? { (try? db.first("SELECT * FROM claude_jobs WHERE id = ?", [id])).flatMap { $0.map(ClaudeJob.init) } }

    func jobs(limit: Int = 50) -> [ClaudeJob] {
        ((try? db.query("SELECT * FROM claude_jobs ORDER BY id DESC LIMIT ?", [limit])) ?? []).map(ClaudeJob.init)
    }

    /// The next job to run in the background, oldest first. Only one runs at a time.
    func nextQueuedJob() -> ClaudeJob? {
        guard (try? db.scalarInt("SELECT count(*) FROM claude_jobs WHERE state = 'running'")) == 0 else { return nil }
        return (try? db.first("SELECT * FROM claude_jobs WHERE state = 'queued' ORDER BY id LIMIT 1")).flatMap { $0.map(ClaudeJob.init) }
    }

    func activeJobs() -> [ClaudeJob] {
        ((try? db.query("SELECT * FROM claude_jobs WHERE state IN ('queued','running','handed_off','waiting') ORDER BY id")) ?? []).map(ClaudeJob.init)
    }

    func jobsNeedingAttention() -> [ClaudeJob] {
        ((try? db.query("SELECT * FROM claude_jobs WHERE state IN ('handed_off','waiting','failed') ORDER BY id DESC")) ?? []).map(ClaudeJob.init)
    }

    /// An active job for the same task and object, so a second click doesn't queue a duplicate.
    func activeJob(_ task: ClaudeTask, objectKind: String?, objectId: Int?) -> ClaudeJob? {
        activeJobs().first { $0.task == task && $0.objectKind == objectKind && $0.objectId == objectId }
    }

    func setJobState(_ id: Int, _ state: JobState, summary: String? = nil, error: String? = nil) throws {
        let now = ISO.instant(Date())
        try db.execute("""
            UPDATE claude_jobs SET state = ?,
              started_at = CASE WHEN ? IN ('running','handed_off') AND started_at IS NULL THEN ? ELSE started_at END,
              finished_at = CASE WHEN ? IN ('done','failed','canceled') THEN ? ELSE finished_at END,
              result_summary = COALESCE(?, result_summary), error = COALESCE(?, error)
            WHERE id = ?
            """, [state.rawValue, state.rawValue, now, state.rawValue, now, summary, error, id])
        audit("job_\(state.rawValue)", entity: "job", id: id, detail: summary ?? error)
    }

    /// Called by the MCP server after a write tagged with `job_id`. Returns true if this write finished the job.
    @discardableResult
    func attachJobResult(_ id: Int, tool: String, args: [String: Any], count: Int) throws -> Bool {
        guard let job = job(id) else { return false }
        var results = job.results
        results[tool, default: 0] += max(count, 1)
        let json = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        let summary = ClaudeJob.summary(results)
        try db.execute("UPDATE claude_jobs SET results_json = ?, result_summary = COALESCE(?, result_summary) WHERE id = ?", [json, summary, id])
        if job.state == .handedOff { try setJobState(id, .waiting) }
        if job.state.isActive && job.task.isFinished(by: tool, args: args) {
            try setJobState(id, .done, summary: summary)
            return true
        }
        return false
    }

    /// Jobs left running when the app quit can't be resumed.
    func failInterruptedJobs() {
        _ = try? db.execute("UPDATE claude_jobs SET state = 'failed', error = 'The app quit before Claude finished.', finished_at = ? WHERE state = 'running'",
                            [ISO.instant(Date())])
    }
}
