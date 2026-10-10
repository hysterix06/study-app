import Foundation

/// How much one session holds, by its size.
public extension SessionMode {
    /// Cards in a topic session's warm-up.
    var warmupCards: Int { self == .quick ? 5 : self == .standard ? 10 : 15 }
    /// Problems in a topic session's practice.
    var problems: Int { self == .quick ? 1 : self == .standard ? 3 : 6 }
    /// A quick session leaves out explaining it back.
    var explains: Bool { self != .quick }
    /// Pages in a notebook session.
    var notebookPages: Int { self == .quick ? 2 : self == .standard ? 6 : 12 }
    /// Cards in a review session.
    var reviewCards: Int { self == .quick ? 15 : self == .standard ? 30 : 60 }
    /// Problems in an exam-prep session's practice.
    var examProblems: Int { self == .quick ? 2 : self == .standard ? 5 : 10 }
}

/// The steps of a session, in order. Saved with the session, so it picks up where the student left it.
public enum SessionStep: String, Codable, Sendable {
    /// Notebook: the pages to write, one at a time.
    case pages
    /// Topic: due cards first, then the lesson, the course's problems, explaining it back, and keeping the cards.
    case warmup, learn, practice, explain, lockin
    /// Review: due cards only.
    case cards
    /// Exam prep: cover each page, recall it, check it, rate it; then exam-style practice.
    case recall
    case done

    public var title: String {
        switch self {
        case .pages: return "Write"
        case .warmup: return "Warm-up"
        case .learn: return "Learn"
        case .practice: return "Practice"
        case .explain: return "Explain"
        case .lockin: return "Lock in"
        case .cards: return "Review"
        case .recall: return "Recall"
        case .done: return "Done"
        }
    }
}

/// Where a session is: its steps, the step it's on, its topics and how far through them it is.
public struct SessionProgress: Codable, Equatable, Sendable {
    public var steps: [SessionStep]
    public var topicIds: [Int]
    /// The page, card or problem the current step is on.
    public var index: Int
    /// Problems this session practises, chosen when it starts.
    public var problemIds: [Int]
    public var cardsKept: [Int]

    public init(steps: [SessionStep], topicIds: [Int] = [], index: Int = 0, problemIds: [Int] = [], cardsKept: [Int] = []) {
        self.steps = steps; self.topicIds = topicIds; self.index = index; self.problemIds = problemIds; self.cardsKept = cardsKept
    }

    enum CodingKeys: String, CodingKey { case steps, topicIds = "topic_ids", index, problemIds = "problem_ids", cardsKept = "cards_kept" }
}

public extension StudySession {
    var progress: SessionProgress? { JSON.decode(SessionProgress.self, progressJson) }
    var currentStep: SessionStep { step.flatMap(SessionStep.init) ?? progress?.steps.first ?? .done }
    var sessionMode: SessionMode { SessionMode(rawValue: mode ?? "") ?? .standard }
}

public extension StudyStore {
    func session(_ id: Int) -> StudySession? { (try? db.first("SELECT * FROM study_sessions WHERE id = ?", [id])).map(StudySession.init) }

    /// Starts the session a suggestion describes, or returns the unfinished one it continues.
    func beginSession(_ pick: SessionPick, mode: SessionMode, now: Date = Date()) throws -> StudySession {
        if let id = pick.sessionId, let open = session(id), open.endedAt == nil { return open }
        var progress: SessionProgress
        var topicId: Int?
        var courseId = pick.courseId
        switch pick.kind {
        case .notebook:
            let ids = pick.topicIds.isEmpty ? pick.topicId.map { [$0] } ?? [] : pick.topicIds
            guard !ids.isEmpty else { throw StoreError.invalid("No pages to write.") }
            progress = SessionProgress(steps: [.pages], topicIds: Array(ids.prefix(mode.notebookPages)))
        case .topic:
            guard let id = pick.topicId, let t = topic(id) else { throw StoreError.notFound("That topic isn't in the path any more.") }
            topicId = id
            courseId = t.courseId
            var steps: [SessionStep] = []
            if !reviewQueue(courseId: t.courseId, limit: 1, now: now).isEmpty { steps.append(.warmup) }
            steps.append(.learn)
            let problems = practiceFor(topicIds: [id], count: mode.problems)
            if !problems.isEmpty { steps.append(.practice) }
            if mode.explains { steps.append(.explain) }
            steps.append(.lockin)
            progress = SessionProgress(steps: steps, topicIds: [id], problemIds: problems.map(\.id))
        case .review:
            progress = SessionProgress(steps: [.cards])
        case .examPrep:
            guard !pick.topicIds.isEmpty else { throw StoreError.invalid("This exam has no topics to review yet.") }
            let problems = practiceFor(topicIds: pick.topicIds, count: mode.examProblems, examFirst: true, shakyFirst: true)
            progress = SessionProgress(steps: problems.isEmpty ? [.recall, .lockin] : [.recall, .practice, .lockin], topicIds: pick.topicIds,
                                       problemIds: problems.map(\.id))
        }
        let id = try db.execute("""
            INSERT INTO study_sessions(course_id, assignment_id, topic_id, kind, mode, step, progress_json, started_at, created_by)
            VALUES(?,?,?,?,?,?,?,?,'user')
            """, [courseId, pick.assignmentId, topicId, pick.kind.rawValue, mode.rawValue, progress.steps.first?.rawValue,
                  JSON.encode(progress), ISO.instant(now)]).lastInsertId
        audit("session_started", entity: "session", id: id, detail: pick.kind.rawValue)
        return session(id)!
    }

    /// Saves where the session is, after every step, so leaving never loses anything.
    func saveSession(_ id: Int, step: SessionStep, progress: SessionProgress) throws {
        try db.execute("UPDATE study_sessions SET step = ?, progress_json = ? WHERE id = ?", [step.rawValue, JSON.encode(progress), id])
    }

    /// Ends a session: its topics were studied today, and their mastery moves with what the student rated.
    func finishSession(_ id: Int, summary: String? = nil, now: Date = Date()) throws {
        guard let s = session(id) else { return }
        try db.execute("UPDATE study_sessions SET step = 'done', ended_at = ?, summary = COALESCE(?, summary) WHERE id = ?", [ISO.instant(now), summary, id])
        let topics = Set((s.progress?.topicIds ?? []) + [s.topicId].compactMap { $0 })
        for t in topics {
            try db.execute("UPDATE path_topics SET last_studied_at = ? WHERE id = ?", [ISO.instant(now), t])
            refreshMastery(topicId: t, now: now)
        }
        audit("session_finished", entity: "session", id: id, detail: s.kind)
    }

    // MARK: Practice

    /// Problems for these topics: the course's own first (its exam-style ones first for exam prep), ones not tried yet
    /// before ones tried, ones missed last time before ones got; written ones only after the course's run out.
    func practiceFor(topicIds: [Int], count: Int, examFirst: Bool = false, shakyFirst: Bool = false) -> [PracticeItem] {
        guard !topicIds.isEmpty, count > 0 else { return [] }
        let items = topicIds.flatMap { practiceItems(topicId: $0) }
        let last: [Int: String] = Dictionary(((try? db.query("""
            SELECT item_id, self_rating FROM practice_attempts WHERE item_id IN (\(items.map { String($0.id) }.joined(separator: ",").nilIfEmpty ?? "0"))
            ORDER BY attempted_at
            """)) ?? []).map { ($0.i("item_id"), $0.str("self_rating")) }, uniquingKeysWith: { _, b in b })
        let shaky: Set<Int> = shakyFirst ? Set(topicIds.compactMap { topic($0) }.flatMap { shakyTopics(courseId: $0.courseId) }) : []
        func rank(_ i: PracticeItem) -> (Int, Int, Int, Int, Int, Int) {
            let tried = last[i.id]
            return (i.source == "course" ? 0 : 1,
                    shakyFirst && i.topicId.map(shaky.contains) == true ? 0 : 1,
                    examFirst && i.examStyle ? 0 : 1,
                    tried == nil ? 0 : tried == "missed" ? 1 : tried == "partly" ? 2 : 3,
                    topicIds.firstIndex(of: i.topicId ?? -1) ?? 99,
                    i.id)
        }
        return Array(items.sorted { rank($0) < rank($1) }.prefix(count))
    }

    /// The student's own rating of an attempt. The AI's check is kept beside it as advice; it never sets the rating.
    @discardableResult
    func recordAttempt(itemId: Int, sessionId: Int?, answer: String?, rating: String, aiFeedback: String? = nil, aiVerdict: String? = nil,
                       durationMs: Int? = nil, now: Date = Date()) throws -> Int {
        guard ["got", "partly", "missed"].contains(rating) else { throw StoreError.invalid("Rate it got, partly or missed.") }
        let id = try db.execute("""
            INSERT INTO practice_attempts(item_id, session_id, attempted_at, answer_text, self_rating, ai_feedback_md, ai_verdict, duration_ms)
            VALUES(?,?,?,?,?,?,?,?)
            """, [itemId, sessionId, ISO.instant(now), answer?.nilIfEmpty, rating, aiFeedback, aiVerdict, durationMs]).lastInsertId
        if let t = practiceItem(itemId)?.topicId { refreshMastery(topicId: t, now: now) }
        return id
    }

    /// The student's own rating of explaining a topic back (nailed, mostly, not_yet) or of recalling its notebook page
    /// in exam prep (solid, shaky).
    @discardableResult
    func recordCheck(topicId: Int, sessionId: Int?, kind: String, rating: String, answer: String? = nil, aiFeedback: String? = nil,
                     now: Date = Date()) throws -> Int {
        let allowed = kind == "explain" ? ["nailed", "mostly", "not_yet"] : kind == "notebook_review" ? ["solid", "shaky"] : []
        guard allowed.contains(rating) else { throw StoreError.invalid("That rating doesn't fit a \(kind) check.") }
        let id = try db.execute("""
            INSERT INTO topic_checks(topic_id, session_id, kind, rating, answer_text, ai_feedback_md, at) VALUES(?,?,?,?,?,?,?)
            """, [topicId, sessionId, kind, rating, answer?.nilIfEmpty, aiFeedback, ISO.instant(now)]).lastInsertId
        refreshMastery(topicId: topicId, now: now)
        return id
    }

    // MARK: Cards

    /// Keeps a lesson's cards (the ones the student didn't remove or rewrote), for spaced review. A card already kept
    /// for this topic isn't added twice.
    @discardableResult
    func keepCards(topicId: Int, _ cards: [LessonCard], now: Date = Date()) throws -> [Int] {
        guard let t = topic(topicId) else { return [] }
        let existing = Set(((try? db.query("SELECT front FROM cards WHERE topic_id = ?", [topicId])) ?? []).map { $0.str("front").lowercased() })
        var ids: [Int] = []
        try db.transaction {
            for c in cards {
                let front = c.front.trimmingCharacters(in: .whitespacesAndNewlines), back = c.back.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !front.isEmpty, !back.isEmpty, !existing.contains(front.lowercased()) else { continue }
                let id = try insertCard(courseId: t.courseId, materialId: nil, conceptId: nil, questionId: nil, front: String(front.prefix(400)),
                                        back: String(back.prefix(800)), locators: nil, status: "active", createdBy: "user", now: now)
                try db.execute("UPDATE cards SET topic_id = ? WHERE id = ?", [topicId, id])
                ids.append(id)
            }
        }
        return ids
    }
}
