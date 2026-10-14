import Foundation

/// AI is one feature (UI remap principle 6): every AI task is a job with one label, one queue and one Activity log,
/// whichever engine runs it.
///
/// - Automatic: a built-in engine (Apple, a cloud provider, a local model) or a CLI such as Claude Code runs it in the
///   background. Queued → Running → Done or Failed.
/// - Chat: a conversational task in the app's chat panel. Running → Done when its final tool is called.
/// - Desktop (handoff): the app copies the prompt (carrying the job id) and opens the student's AI app.
///   Handed off → Waiting → Done. MCP writes tagged with the job id attach their results.
/// - Paste: the prompt goes to any chatbot and the JSON answer is pasted back. Handed off → Done.
public enum AITask: String, CaseIterable, Codable, Sendable {
    // Files: free AI reads new files quietly in the background.
    /// Places files the sorting rules weren't sure about.
    case sortFiles = "sort_files"
    /// Reads a syllabus or brief: deadlines, learning outcomes and the weekly plan.
    case extractDeadlines = "extract_deadlines"
    /// Labels the problems split out of a problem set or class example (kind, difficulty, topic).
    case extractPractice = "extract_practice"
    /// Labels the questions split out of a past exam, so marks per topic show what earns marks.
    case extractExam = "extract_exam"
    // Course building: the course builder (Claude) lays out each course, then writes its notebook guide unit by unit,
    // then lessons a few topics ahead of the student. Each has a basic version free AI can run.
    /// Lays out the course: units of numbered topics, in the best order to learn them.
    case buildPath = "build_path"
    /// Writes the notebook guide for one unit: the words, pictures and formulas of each topic's page.
    case writeNotebook = "write_notebook"
    /// Writes the lessons for a few topics.
    case writeLessons = "write_lessons"
    case buildPathBasic = "build_path_basic"
    case writeNotebookBasic = "write_notebook_basic"
    case writeLessonsBasic = "write_lessons_basic"
    // In a session, right away (no job): advice the student may ignore. Their own rating decides.
    /// Looks at the student's answer to a practice problem.
    case checkAnswer = "check_answer"
    /// Reads the student's explanation of a topic and says what's missing.
    case explainFeedback = "explain_feedback"
    // Conversations.
    case checkDraft = "check_draft"
    // Retired in v6. Kept so jobs from older versions still load; they never run.
    case process, examPatterns = "exam_patterns", reviewNotes = "review_notes", quiz, recall, explain, practice, weeklyPlan = "weekly_plan"
    /// A task this version doesn't know (a job from a newer or much older version).
    case legacy

    /// Tasks from before v6 (per-lecture processing, Cornell sheets, handwriting checks…), replaced by the notebook,
    /// the path and guided sessions.
    public var isRetired: Bool {
        switch self {
        case .process, .examPatterns, .reviewNotes, .quiz, .recall, .explain, .practice, .weeklyPlan, .legacy: return true
        default: return false
        }
    }

    /// Tasks the current version can run.
    public static var current: [AITask] { allCases.filter { !$0.isRetired } }

    /// One label per task; it never changes with the engine (the engine is shown next to it).
    public var label: String {
        switch self {
        case .sortFiles: return "Sort files"
        case .extractDeadlines: return "Read syllabus"
        case .extractPractice: return "Read practice problems"
        case .extractExam: return "Read past exam"
        case .buildPath: return "Lay out the course"
        case .writeNotebook: return "Write the notebook guide"
        case .writeLessons: return "Write lessons"
        case .buildPathBasic: return "Lay out the course (basic)"
        case .writeNotebookBasic: return "Write the notebook guide (basic)"
        case .writeLessonsBasic: return "Write lessons (basic)"
        case .checkAnswer: return "Check my answer"
        case .explainFeedback: return "Feedback on my explanation"
        case .checkDraft: return "Check my draft"
        case .process: return "Process lecture"
        case .examPatterns: return "Analyse past exam"
        case .reviewNotes: return "Review my handwritten notes"
        case .quiz: return "Quiz me"
        case .recall: return "Recall session"
        case .explain: return "Explain it back"
        case .practice: return "Practice problems"
        case .weeklyPlan: return "Plan my week"
        case .legacy: return "Older task"
        }
    }

    /// Short noun phrase for status lines and job history: "Reading HM210 Syllabus".
    public var activity: String {
        switch self {
        case .sortFiles: return "Sorting"
        case .extractDeadlines: return "Reading"
        case .extractPractice: return "Reading the problems in"
        case .extractExam: return "Reading the exam"
        case .buildPath, .buildPathBasic: return "Laying out"
        case .writeNotebook, .writeNotebookBasic: return "Writing the notebook guide for"
        case .writeLessons, .writeLessonsBasic: return "Writing lessons for"
        case .checkDraft: return "Checking the draft for"
        default: return label
        }
    }

    /// The MCP prompt for running this task in an AI app or Claude Code. Background file tasks and the basic course
    /// tasks have none: they are pipelines the app runs itself.
    public var prompt: String? {
        switch self {
        case .extractDeadlines: return "extract_deadlines"
        case .checkDraft: return "check_draft"
        case .buildPath: return "build_course_path"
        case .writeNotebook: return "write_notebook"
        case .writeLessons: return "write_lessons"
        default: return nil
        }
    }

    /// Builds a course's path, notebook guide or lessons.
    public var isCourseBuilding: Bool { builderTier != nil }

    /// What a course-building task writes: `full` (the course builder) or `basic` (free AI). A basic version never
    /// replaces a full one.
    public var builderTier: String? {
        switch self {
        case .buildPath, .writeNotebook, .writeLessons: return "full"
        case .buildPathBasic, .writeNotebookBasic, .writeLessonsBasic: return "basic"
        default: return nil
        }
    }

    /// Tasks that talk with the student run in a chat: the app's chat panel or the student's AI app.
    public var conversational: Bool { self == .checkDraft }

    /// The engine lane: bulk work prefers the on-device model (free, private, no daily limit); work the student reads
    /// prefers the best free model.
    public var engineLane: EngineLane {
        switch self {
        case .buildPath, .writeNotebook, .writeLessons: return .builder
        case .checkDraft, .buildPathBasic, .writeNotebookBasic, .writeLessonsBasic, .checkAnswer, .explainFeedback: return .quality
        default: return .bulk
        }
    }

    /// Jobs in different queue lanes run side by side: building a course (even its basic version, one request per
    /// topic) never holds up sorting new files.
    public var queueLane: String { isCourseBuilding ? "builder" : "everyday" }

    /// A smaller version to fall back on when no engine can run this task (a strong-model task → its basic version).
    public var degradesTo: AITask? {
        switch self {
        case .buildPath: return .buildPathBasic
        case .writeNotebook: return .writeNotebookBasic
        case .writeLessons: return .writeLessonsBasic
        default: return nil
        }
    }

    /// Context the model needs, in tokens. Engines below it are skipped: writing for the student needs at least 8k.
    public var minContext: Int {
        switch self {
        case .buildPath, .writeNotebook, .writeLessons: return 100_000
        case .checkDraft, .buildPathBasic, .writeNotebookBasic, .writeLessonsBasic: return 8_000
        default: return 4_000
        }
    }

    /// Judging the student's work (checking an answer, feedback on an explanation) needs a model that reasons reliably.
    /// Apple's on-device model is fine for sorting and reading files, but in testing it marked right answers wrong
    /// with invented maths, so it never grades.
    public var needsReasoning: Bool { self == .checkAnswer || self == .explainFeedback }

    /// Runs as a conversation or a tool loop, so the model must support tools. Pipelines build the requests themselves.
    public var usesTools: Bool { conversational || engineLane == .builder }

    /// Lower runs first; 0 means the student is waiting for it right now.
    public var defaultPriority: Int {
        switch self {
        case .checkDraft, .checkAnswer, .explainFeedback: return 0
        case .sortFiles: return 20
        case .extractDeadlines: return 30
        case .extractExam: return 40
        case .extractPractice: return 50
        case .buildPath, .buildPathBasic: return 60
        case .writeNotebook, .writeNotebookBasic: return 65
        case .writeLessons, .writeLessonsBasic: return 70
        default: return 90
        }
    }

    /// The MCP write that finishes the task when an AI app or a tool loop runs it.
    public func isFinished(by tool: String, args: [String: Any]) -> Bool {
        switch self {
        case .sortFiles: return tool == "set_material_use"
        case .extractDeadlines: return tool == "propose_assignments" || tool == "save_material_scan"
        case .extractPractice, .extractExam: return tool == "label_practice_items"
        case .buildPath, .buildPathBasic: return tool == "save_path"
        // Done when every page or lesson the job asked for is written: see `builderWorkDone`.
        case .writeNotebook, .writeNotebookBasic, .writeLessons, .writeLessonsBasic: return false
        case .checkDraft: return tool == "save_note" && (args["kind"] as? String) == "rubric_check"
        default: return false
        }
    }
}

/// Which engines a task prefers. Bulk work (sorting and reading files) prefers the on-device model: free, private and
/// with no daily limit. Work the student reads (feedback, tutoring) prefers the best free model. Course building prefers
/// a strong model, and otherwise falls back to a basic version on free AI.
public enum EngineLane: String, Sendable { case bulk, quality, builder }

public typealias ClaudeTask = AITask

public enum JobMode: String, Codable { case automatic, desktop, chat, paste }

/// A line in a job's log: what the AI was asked and answered, how far it got, and what the student did.
public struct JobEvent: Identifiable, Hashable {
    public enum Kind: String { case start, request, reply, progress, error, control, finish }
    public var id: Int
    public var jobId: Int
    public var at: Date
    public var kind: Kind
    public var text: String
    /// The full prompt or reply, relative to the root.
    public var file: String?

    init(row r: Row) {
        id = r.i("id"); jobId = r.i("job_id")
        at = ISO.parse(r.str("at")) ?? Date()
        kind = Kind(rawValue: r.str("kind")) ?? .progress
        text = r.str("text"); file = r.string("file")
    }
}

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
    public var task: AITask
    public var args: [String: String]
    public var objectKind: String?
    public var objectId: Int?
    public var label: String
    public var mode: JobMode
    /// "openrouter:model", "apple.ondevice", "cli.claude", "app.cursor"… nil for jobs from before v5.
    public var engine: String?
    public var state: JobState
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var resultSummary: String?
    /// Items written per tool, e.g. ["save_concepts": 14, "propose_cards": 22].
    public var results: [String: Int]
    public var error: String?
    public var tokensIn: Int
    public var tokensOut: Int
    public var costUSD: Double?
    /// `everyday` or `builder`: each lane runs one job at a time, so a long course build never blocks sorting files.
    public var lane: String
    /// Lower runs first. 0 is "the student is waiting for this".
    public var priority: Int
    public var attempts: Int
    /// Engines that already failed this job, so a retry moves on to the next one.
    public var enginesTried: [String]
    /// Don't start before this (backing off after a rate limit, or delayed by the student).
    public var notBefore: Date?
    public var courseId: Int?
    /// Held by the student: it stays in the queue but doesn't start until they resume it.
    public var paused: Bool

    /// The error a job canceled by the student carries, so the course builder doesn't queue the same step again.
    public static let canceledByStudent = "Canceled by you."

    /// Started by the app on its own (sorting and reading new files): no toasts, and a failure that every engine shares
    /// becomes one Needs a look row instead of an alert.
    public var isQuiet: Bool { args["quiet"] == "1" }

    init(row r: Row) {
        id = r.i("id")
        task = AITask(rawValue: r.str("task")) ?? .legacy
        args = (try? JSONDecoder().decode([String: String].self, from: Data(r.str("args_json").utf8))) ?? [:]
        objectKind = r.string("object_kind")
        objectId = r.int("object_id")
        label = r.str("label")
        mode = JobMode(rawValue: r.str("mode")) ?? .desktop
        engine = r.string("engine")
        state = JobState(rawValue: r.str("state")) ?? .failed
        createdAt = ISO.parse(r.str("created_at")) ?? Date()
        startedAt = r.string("started_at").flatMap { ISO.parse($0) }
        finishedAt = r.string("finished_at").flatMap { ISO.parse($0) }
        resultSummary = r.string("result_summary")
        results = (try? JSONDecoder().decode([String: Int].self, from: Data(r.str("results_json").utf8))) ?? [:]
        error = r.string("error")
        tokensIn = r.i("tokens_in"); tokensOut = r.i("tokens_out")
        costUSD = r.double("cost_usd")
        lane = r.string("lane") ?? "everyday"; priority = r.int("priority") ?? 50; attempts = r.i("attempts")
        enginesTried = JSON.stringArray(r.string("engines_tried")); notBefore = r.string("not_before").flatMap { ISO.parse($0) }
        courseId = r.int("course_id")
        paused = r.int("paused") == 1
    }

    /// "Sorted 3 files · Found 2 deadlines to confirm".
    public static func summary(_ results: [String: Int]) -> String? {
        let phrases: [(tool: String, verb: String, one: String, many: String)] = [
            ("save_path", "Laid out", "topic", "topics"),
            ("save_notebook", "Wrote", "notebook page", "notebook pages"),
            ("save_lessons", "Wrote", "lesson", "lessons"),
            ("set_material_use", "Sorted", "file", "files"),
            ("label_practice_items", "Labelled", "practice problem", "practice problems"),
            ("save_practice_items", "Added", "practice problem", "practice problems"),
            ("propose_assignments", "Found", "deadline to confirm", "deadlines to confirm"),
            ("save_material_scan", "Read", "file", "files"),
            ("propose_study_blocks", "Proposed", "study block", "study blocks"),
            ("save_note", "Saved", "note", "notes"),
            ("record_session", "Recorded", "session", "sessions"),
        ]
        let parts = phrases.compactMap { p -> String? in
            guard let n = results[p.tool], n > 0 else { return nil }
            return "\(p.verb) \(n) \(n == 1 ? p.one : p.many)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public extension StudyStore {
    @discardableResult
    func enqueueJob(_ task: AITask, args: [String: String], objectKind: String?, objectId: Int?, label: String, mode: JobMode, engine: String? = nil,
                    priority: Int? = nil, courseId: Int? = nil) throws -> Int {
        let json = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        let id = try db.execute("""
            INSERT INTO claude_jobs(task, args_json, object_kind, object_id, label, mode, engine, lane, priority, course_id)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [task.rawValue, json, objectKind, objectId, label, mode.rawValue, engine, task.queueLane, priority ?? task.defaultPriority,
                  courseId]).lastInsertId
        audit("job_queued", entity: "job", id: id, detail: label)
        return id
    }

    func job(_ id: Int) -> ClaudeJob? { (try? db.first("SELECT * FROM claude_jobs WHERE id = ?", [id])).flatMap { $0.map(ClaudeJob.init) } }

    func jobs(limit: Int = 50) -> [ClaudeJob] {
        ((try? db.query("SELECT * FROM claude_jobs ORDER BY id DESC LIMIT ?", [limit])) ?? []).map(ClaudeJob.init)
    }

    /// The next job a queue lane should start: highest priority first, then oldest, skipping any that are backing off.
    /// `maxPriority` keeps a lane to urgent work (while the student is in a session, only what they're waiting for).
    func nextQueuedJob(lane: String, now: Date = Date(), maxPriority: Int = .max) -> ClaudeJob? {
        (try? db.first("""
            SELECT * FROM claude_jobs WHERE state = 'queued' AND mode = 'automatic' AND lane = ? AND priority <= ? AND paused = 0
              AND (not_before IS NULL OR not_before <= ?)
            ORDER BY priority, id LIMIT 1
            """, [lane, maxPriority, ISO.instant(now)])).flatMap { $0.map(ClaudeJob.init) }
    }

    /// The next job to run, in the single-queue style older code expects.
    func nextQueuedJob() -> ClaudeJob? {
        guard (try? db.scalarInt("SELECT count(*) FROM claude_jobs WHERE state = 'running'")) == 0 else { return nil }
        return nextQueuedJob(lane: "everyday") ?? nextQueuedJob(lane: "builder")
    }

    /// When the earliest backing-off job may start, so the runner can wake up for it.
    func nextJobWake(now: Date = Date()) -> Date? {
        (try? db.scalarString("SELECT min(not_before) FROM claude_jobs WHERE state = 'queued' AND paused = 0 AND not_before > ?", [ISO.instant(now)]))
            .flatMap { $0 }.flatMap { ISO.parse($0) }
    }

    /// Puts a job back in the queue after a failure: on the same engine after `notBefore` (a rate limit or a dropped
    /// connection), or right away on the next engine once `failedEngine` is ruled out.
    func requeueJob(_ id: Int, failedEngine: String? = nil, notBefore: Date? = nil, error: String? = nil) throws {
        if let failedEngine, let job = job(id), !job.enginesTried.contains(failedEngine) {
            try db.execute("UPDATE claude_jobs SET engines_tried = ? WHERE id = ?", [JSON.string(job.enginesTried + [failedEngine]), id])
        }
        try db.execute("""
            UPDATE claude_jobs SET state = 'queued', attempts = attempts + 1, not_before = ?, error = COALESCE(?, error) WHERE id = ?
            """, [notBefore.map { ISO.instant($0) }, error, id])
    }

    /// Switches a job to another task (a strong-model task falling back to its basic version) and gives every engine
    /// a fresh try.
    func setJobTask(_ id: Int, _ task: AITask) throws {
        try db.execute("UPDATE claude_jobs SET task = ?, lane = ?, engines_tried = '[]', not_before = NULL WHERE id = ?",
                       [task.rawValue, task.queueLane, id])
    }

    func queuedJobCount(lane: String? = nil) -> Int {
        (try? db.scalarInt("SELECT count(*) FROM claude_jobs WHERE state IN ('queued','running') AND paused = 0" + (lane == nil ? "" : " AND lane = ?"),
                           lane.map { [$0] } ?? [])) ?? 0
    }

    func activeJobs() -> [ClaudeJob] {
        ((try? db.query("SELECT * FROM claude_jobs WHERE state IN ('queued','running','handed_off','waiting') ORDER BY id")) ?? []).map(ClaudeJob.init)
    }

    func jobsNeedingAttention() -> [ClaudeJob] {
        ((try? db.query("SELECT * FROM claude_jobs WHERE state IN ('handed_off','waiting','failed') ORDER BY id DESC")) ?? []).map(ClaudeJob.init)
    }

    /// An active job for the same task and object, so a second click doesn't queue a duplicate.
    func activeJob(_ task: AITask, objectKind: String?, objectId: Int?) -> ClaudeJob? {
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
        if job.state.isActive && (job.task.isFinished(by: tool, args: args) || builderWorkDone(id)) {
            try setJobState(id, .done, summary: summary)
            return true
        }
        return false
    }

    /// Moves a job to another engine or mode (e.g. Claude Code went away, or the student picked a different engine).
    func setJobEngine(_ id: Int, mode: JobMode, engine: String?) throws {
        try db.execute("UPDATE claude_jobs SET mode = ?, engine = ? WHERE id = ?", [mode.rawValue, engine, id])
    }

    /// Adds tokens and cost from one engine request to the job.
    func addJobUsage(_ id: Int, tokensIn: Int, tokensOut: Int, costUSD: Double?) {
        _ = try? db.execute("""
            UPDATE claude_jobs SET tokens_in = tokens_in + ?, tokens_out = tokens_out + ?,
              cost_usd = CASE WHEN ? IS NULL THEN cost_usd ELSE COALESCE(cost_usd, 0) + ? END WHERE id = ?
            """, [tokensIn, tokensOut, costUSD, costUSD, id])
    }

    // MARK: Steering (the Activity window)

    /// Holds a job in the queue until the student resumes it. A running job goes back to the queue (the runner stops it).
    func pauseJob(_ id: Int) throws {
        try db.execute("UPDATE claude_jobs SET paused = 1, state = 'queued' WHERE id = ? AND state IN ('queued','running')", [id])
    }

    /// Back in line, ready to start.
    func resumeJob(_ id: Int) throws {
        try db.execute("UPDATE claude_jobs SET paused = 0, not_before = NULL WHERE id = ? AND state = 'queued'", [id])
    }

    /// Waits until `until`, then starts as usual. A running job goes back to the queue (the runner stops it).
    func delayJob(_ id: Int, until: Date) throws {
        try db.execute("UPDATE claude_jobs SET paused = 0, not_before = ?, state = 'queued' WHERE id = ? AND state IN ('queued','running')",
                       [ISO.instant(until), id])
    }

    /// Next in its lane: ahead of everything else, even during a session.
    func runJobNext(_ id: Int) throws {
        try db.execute("UPDATE claude_jobs SET paused = 0, not_before = NULL, priority = 0 WHERE id = ? AND state = 'queued'", [id])
    }

    /// Queued jobs in the order they'll start: ready ones in queue order, then delayed ones by time, then paused ones.
    func upcomingJobs(now: Date = Date()) -> [ClaudeJob] {
        ((try? db.query("""
            SELECT * FROM claude_jobs WHERE state = 'queued' AND mode = 'automatic'
            ORDER BY paused, CASE WHEN not_before > ? THEN not_before ELSE '' END, priority, id
            """, [ISO.instant(now)])) ?? []).map(ClaudeJob.init)
    }

    /// Nothing starts while the student has paused AI. `Date.distantFuture` means until they resume it.
    var aiPausedUntil: Date? {
        get { setting("ai_paused_until").flatMap { ISO.parse($0) } }
        set { setSetting("ai_paused_until", newValue.map { ISO.instant($0) }) }
    }

    func aiPaused(now: Date = Date()) -> Bool { aiPausedUntil.map { $0 > now } ?? false }

    // MARK: Job log

    /// One line in a job's log. `file` is a full prompt or reply saved under `AI log/`, relative to the root.
    func addJobEvent(_ jobId: Int, _ kind: JobEvent.Kind, _ text: String, file: String? = nil) {
        _ = try? db.execute("INSERT INTO job_events(job_id, kind, text, file) VALUES(?,?,?,?)", [jobId, kind.rawValue, text, file])
    }

    /// A job's log, oldest first (its last `limit` lines).
    func jobEvents(_ jobId: Int, limit: Int = 500) -> [JobEvent] {
        ((try? db.query("SELECT * FROM (SELECT * FROM job_events WHERE job_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id", [jobId, limit])) ?? [])
            .map(JobEvent.init)
    }

    /// Full prompts and replies are kept for two weeks; the log lines stay with their job.
    func pruneAILog(olderThanDays days: Double = 14, now: Date = Date()) {
        let cutoff = now.adding(days: -days)
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: paths.aiLog.path)) ?? [] {
            let url = paths.aiLog.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
        _ = try? db.execute("UPDATE job_events SET file = NULL WHERE file IS NOT NULL AND at < ?", [ISO.instant(cutoff)])
    }

    /// After a relaunch: jobs that were running start again (up to six tries), and hand-offs nobody finished in a week
    /// are closed. Retired tasks from older versions are closed too.
    func requeueInterruptedJobs(now: Date = Date()) {
        let stamp = ISO.instant(now)
        _ = try? db.execute("""
            UPDATE claude_jobs SET state = 'failed', error = 'The app quit while this was running, too many times.', finished_at = ?
            WHERE state = 'running' AND attempts >= 5
            """, [stamp])
        _ = try? db.execute("UPDATE claude_jobs SET state = 'queued', attempts = attempts + 1 WHERE state = 'running' AND mode = 'automatic'")
        _ = try? db.execute("UPDATE claude_jobs SET state = 'failed', error = 'The app quit during this chat.', finished_at = ? WHERE state = 'running'", [stamp])
        _ = try? db.execute("""
            UPDATE claude_jobs SET state = 'canceled', error = 'Nothing came back from the AI app within a week.', finished_at = ?
            WHERE state IN ('handed_off','waiting') AND created_at < ?
            """, [stamp, ISO.instant(now.adding(days: -7))])
        let retired = AITask.allCases.filter(\.isRetired).map(\.rawValue)
        _ = try? db.execute("""
            UPDATE claude_jobs SET state = 'canceled', error = 'This kind of task was replaced in the new version.', finished_at = ?
            WHERE state IN ('queued','running','handed_off','waiting') AND task IN (\(retired.map { _ in "?" }.joined(separator: ",")))
            """, [stamp] + retired)
    }
}
