import Foundation

/// One piece of course building for the job queue.
public struct BuilderStep: Equatable, Sendable {
    public var task: AITask
    public var courseId: Int
    /// The topics a notebook or lessons step writes (empty when laying out the path).
    public var topicIds: [Int]
    /// "HM210 · Unit 2: Pricing", shown after the task's activity in the job list.
    public var title: String

    public init(task: AITask, courseId: Int, topicIds: [Int], title: String) {
        self.task = task; self.courseId = courseId; self.topicIds = topicIds; self.title = title
    }

    public var args: [String: String] {
        var a = ["course_id": "\(courseId)"]
        if !topicIds.isEmpty { a["topic_ids"] = topicIds.map(String.init).joined(separator: ",") }
        return a
    }
}

public extension ClaudeJob {
    /// The topics a notebook or lessons job writes.
    var topicIds: [Int] { (args["topic_ids"] ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    /// Who wrote a path, page or lesson, for its header: "Claude Code", "Apple Intelligence", "free AI".
    static func authorName(engine: String?) -> String {
        guard let e = engine, !e.isEmpty else { return "AI" }
        if e == "cli.claude" { return "Claude Code" }
        if e.hasPrefix("anthropic") || e.hasPrefix("app.claude") { return "Claude" }
        if e.hasPrefix("apple.") { return "Apple Intelligence" }
        if e.hasPrefix("app.") { return "your AI app" }
        if e == "paste" { return "a chatbot" }
        return "free AI"
    }
}

public extension StudyStore {
    /// Courses the builder works on: this term's courses that aren't archived.
    func coursesToBuild(now: Date = Date()) -> [Course] {
        let today = LocalDate(now, tz: timezone)
        let current = Set(terms().filter { $0.isCurrent || ($0.startDate.adding(days: -30) <= today && today <= $0.endDate.adding(days: 30)) }.map(\.id))
        return courses().filter { !$0.archived && current.contains($0.termId) }
    }

    /// The next piece of building for a course, at `tier` (`full` with the course builder, `basic` with free AI): lay
    /// out the path when there's none (or only a simpler one, or new files changed the course), then the notebook guide
    /// unit by unit, since the student writes it first, then lessons for the next few topics they'll study. Nil when
    /// everything is written. A fuller path, page or lesson is never replaced by a simpler one.
    func nextBuilderStep(courseId: Int, tier: String, lessonsAhead: Int = 3, now: Date = Date()) -> BuilderStep? {
        guard let course = course(courseId), let rank = Self.tierRank[tier], rank > 0 else { return nil }
        let full = tier == "full"
        let name = course.shortName ?? course.code ?? course.name
        let path = self.path(courseId: courseId)
        let pathRank = path.flatMap { Self.tierRank[$0.tier] } ?? -1
        if path == nil || pathRank < rank || (path!.stale && pathRank <= rank && filesSettled(courseId: courseId, now: now)) {
            return BuilderStep(task: full ? .buildPath : .buildPathBasic, courseId: courseId, topicIds: [], title: name)
        }
        let topics = self.topics(courseId: courseId).filter { $0.userState != "hidden" }
        func below(_ written: String?) -> Bool { (written.flatMap { Self.tierRank[$0] } ?? -1) < rank }

        // The notebook guide, a unit at a time, in path order.
        let pages = notebooks(courseId: courseId)
        for (i, unit) in units(courseId: courseId).enumerated() {
            let missing = topics.filter { $0.unitId == unit.id && below(pages[$0.id]?.tier) }
            guard !missing.isEmpty else { continue }
            return BuilderStep(task: full ? .writeNotebook : .writeNotebookBasic, courseId: courseId, topicIds: Array(missing.prefix(12).map(\.id)),
                               title: "\(name) · Unit \(i + 1): \(unit.title)")
        }

        // Lessons a few topics ahead: what the scheduler picks next, then path order.
        let open = topics.filter { !$0.isSkipped && !$0.mastery.isUnderstood }
        let openIds = Set(open.map(\.id))
        let plan = nextSessionPlan(now: now)
        var ahead: [Int] = []
        for pick in [plan.primary].compactMap({ $0 }) + plan.then where pick.courseId == courseId {
            for id in [pick.topicId].compactMap({ $0 }) + pick.topicIds where openIds.contains(id) && !ahead.contains(id) { ahead.append(id) }
        }
        for t in open where !ahead.contains(t.id) { ahead.append(t.id) }
        let needed = ahead.prefix(lessonsAhead).filter { below(lesson(topicId: $0)?.tier) }
        guard !needed.isEmpty else { return nil }
        let titles = needed.compactMap { id in topics.first { $0.id == id }?.title }
        return BuilderStep(task: full ? .writeLessons : .writeLessonsBasic, courseId: courseId, topicIds: Array(needed),
                           title: "\(name) · " + titles.joined(separator: ", "))
    }

    /// A step that failed lately isn't tried again straight away (a course with nothing to read, a model that keeps
    /// answering badly): it waits `hours` before the next try.
    func builderStepFailedRecently(_ step: BuilderStep, hours: Double = 12, now: Date = Date()) -> Bool {
        let since = ISO.instant(now.addingTimeInterval(-hours * 3600))
        let tasks = [step.task.rawValue] + (step.task.degradesTo.map { [$0.rawValue] } ?? [])
        let rows = (try? db.query("""
            SELECT args_json FROM claude_jobs WHERE course_id = ? AND state = 'failed' AND finished_at >= ?
              AND task IN (\(tasks.map { _ in "?" }.joined(separator: ",")))
            """, [step.courseId, since] + tasks)) ?? []
        let topics = Set(step.topicIds)
        return rows.contains { row in
            let ids = (JSON.parse(row.str("args_json")) as? [String: String])?["topic_ids"]?.split(separator: ",").compactMap { Int($0) } ?? []
            return topics.isEmpty || !topics.isDisjoint(with: ids)
        }
    }

    /// Whether a course-building job wrote everything it was asked for: the path, or every page or lesson for its
    /// topics (at its tier or better). Topics that left the path since count as done.
    func builderWorkDone(_ jobId: Int) -> Bool {
        guard let job = job(jobId), let tier = job.task.builderTier, let rank = Self.tierRank[tier] else { return false }
        switch job.task {
        case .buildPath, .buildPathBasic:
            return (job.results["save_path"] ?? 0) > 0
        case .writeNotebook, .writeNotebookBasic, .writeLessons, .writeLessonsBasic:
            let lessons = job.task == .writeLessons || job.task == .writeLessonsBasic
            let ids = job.topicIds
            return !ids.isEmpty && ids.allSatisfy { id in
                guard let t = topic(id), !t.retired, t.userState != "hidden" else { return true }
                let written = lessons ? lesson(topicId: id)?.tier : notebook(topicId: id)?.tier
                return (written.flatMap { Self.tierRank[$0] } ?? -1) >= rank
            }
        default:
            return false
        }
    }

    /// How much of a job's work is written, for "Claude stopped after 3 of 5 pages".
    func builderProgress(_ jobId: Int) -> (done: Int, of: Int)? {
        guard let job = job(jobId), let rank = job.task.builderTier.flatMap({ Self.tierRank[$0] }), !job.topicIds.isEmpty else { return nil }
        let lessons = job.task == .writeLessons || job.task == .writeLessonsBasic
        let done = job.topicIds.filter { id in
            let written = lessons ? lesson(topicId: id)?.tier : notebook(topicId: id)?.tier
            return (written.flatMap { Self.tierRank[$0] } ?? -1) >= rank
        }.count
        return (done, job.topicIds.count)
    }

    // MARK: Keeping the path current

    /// New lectures, readings, examples, syllabi or past exams arrived: the path is rebuilt once they settle.
    func markPathStale(courseId: Int) {
        _ = try? db.execute("UPDATE course_paths SET stale = 1 WHERE course_id = ? AND stale = 0", [courseId])
    }

    /// Files shape the path only once a sync has finished arriving: ten minutes after the newest one.
    func filesSettled(courseId: Int, now: Date = Date()) -> Bool {
        guard let newest = (try? db.scalarString("SELECT max(imported_at) FROM materials WHERE course_id = ?", [courseId])).flatMap({ $0 }),
              let at = ISO.parse(newest) else { return true }
        return now.timeIntervalSince(at) >= 600
    }

    // MARK: When the course builder can't run

    /// The course builder failed on every engine (signed out, plan limit reached): free AI builds the basic version
    /// meanwhile, and the builder isn't tried again until this passes.
    var builderPausedUntil: Date? {
        get { setting("ai_builder_paused_until").flatMap { ISO.parse($0) } }
        set { setSetting("ai_builder_paused_until", newValue.map { ISO.instant($0) }) }
    }

    func builderPaused(now: Date = Date()) -> Bool { builderPausedUntil.map { $0 > now } ?? false }
}

public extension StudyStore {
    /// The course's own text for a topic, in teaching order and within `budget` characters: the chunks the path points
    /// at, or, where a whole file is linked, the chunks that share the most words with the topic.
    func topicCourseChunks(topicId: Int, budget: Int = 12_000) -> [Chunk] {
        guard let t = topic(topicId) else { return [] }
        let words = TopicLinker.words(([t.title, t.summary ?? ""] + t.objectives).joined(separator: " "))
        var picked: [Chunk] = []
        for cov in coverage(topicId: topicId) {
            let all = chunks(materialId: cov.materialId)
            if !cov.chunkIds.isEmpty {
                picked += all.filter { cov.chunkIds.contains($0.id) }
            } else {
                let scored = all.map { c in (c, TopicLinker.overlap(TopicLinker.words([c.heading ?? "", String(c.textMd.prefix(600))].joined(separator: " ")), topic: words)) }
                let best = Set(scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(6).map(\.0.id))
                picked += all.filter { best.contains($0.id) }
            }
        }
        var out: [Chunk] = []
        var used = 0
        for c in picked {
            let size = c.textMd.count + (c.notesMd?.count ?? 0) + 60
            if !out.isEmpty && used + size > budget { break }
            out.append(c)
            used += size
        }
        return out
    }
}
