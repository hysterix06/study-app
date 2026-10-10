import Foundation

/// What decides how well a topic is known. Only the student's own ratings count (practice, explaining it back, exam
/// prep) and how their cards for the topic are holding up. The AI's feedback never does.
public struct MasteryInput: Sendable {
    public struct Attempt: Sendable {
        public var itemId: Int
        /// got, partly or missed.
        public var rating: String
        public var at: Date
        public init(itemId: Int, rating: String, at: Date) { self.itemId = itemId; self.rating = rating; self.at = at }
    }
    public struct Check: Sendable {
        public var rating: String
        public var at: Date
        public init(rating: String, at: Date) { self.rating = rating; self.at = at }
    }

    public var notebookWritten: Bool
    public var lessonDone: Bool
    public var attempts: [Attempt]
    /// Explaining it back: nailed, mostly or not_yet.
    public var explains: [Check]
    /// Exam prep with the notebook page: solid or shaky.
    public var notebookReviews: [Check]
    /// The mean chance of recalling the topic's cards right now (FSRS), or nil without cards.
    public var cardRetrievability: Double?

    public init(notebookWritten: Bool = false, lessonDone: Bool = false, attempts: [Attempt] = [], explains: [Check] = [],
                notebookReviews: [Check] = [], cardRetrievability: Double? = nil) {
        self.notebookWritten = notebookWritten; self.lessonDone = lessonDone; self.attempts = attempts; self.explains = explains
        self.notebookReviews = notebookReviews; self.cardRetrievability = cardRetrievability
    }
}

public enum MasteryRules {
    /// new → familiar (notebook page written) → learning (lesson done or practice started) → practiced (lesson, a
    /// success, and explained or two successes) → solid (two different problems right on different days, explained
    /// well, cards holding). A practised or solid topic needs a refresh when its cards slip, a month passes without
    /// practice, or exam prep finds it shaky.
    public static func compute(_ i: MasteryInput, now: Date, tz: TimeZone = .current) -> Mastery {
        let got = i.attempts.filter { $0.rating == "got" }
        let explainedSome = i.explains.contains { $0.rating != "not_yet" }
        let explainedWell = i.explains.contains { $0.rating == "nailed" || $0.rating == "mostly" }
        var state: Mastery = .new
        if i.notebookWritten { state = .familiar }
        if i.lessonDone || !i.attempts.isEmpty { state = .learning }
        if i.lessonDone && !got.isEmpty && (explainedSome || got.count >= 2) { state = .practiced }
        let days = Set(got.map { LocalDate($0.at, tz: tz) })
        if Set(got.map(\.itemId)).count >= 2 && days.count >= 2 && explainedWell && (i.cardRetrievability ?? 1) >= 0.85 { state = .solid }
        if state == .practiced || state == .solid {
            let lastPractice = (i.attempts.map(\.at) + i.explains.map(\.at)).max()
            let lastShaky = i.notebookReviews.max { $0.at < $1.at }.map { r in r.rating == "shaky" && r.at > (got.map(\.at).max() ?? .distantPast) } ?? false
            let fading = (i.cardRetrievability ?? 1) < 0.7
            let longAgo = lastPractice.map { now.timeIntervalSince($0) > 30 * 86_400 } ?? false
            if fading || longAgo || lastShaky { state = .refresh }
        }
        return state
    }
}

public extension StudyStore {
    func masteryInput(topicId: Int, now: Date = Date()) -> MasteryInput {
        guard let t = topic(topicId) else { return MasteryInput() }
        let attempts = ((try? db.query("""
            SELECT a.item_id, a.self_rating, a.attempted_at FROM practice_attempts a JOIN practice_items p ON p.id = a.item_id
            WHERE p.topic_id = ? ORDER BY a.attempted_at
            """, [topicId])) ?? []).map { MasteryInput.Attempt(itemId: $0.i("item_id"), rating: $0.str("self_rating"), at: ISO.parse($0.str("attempted_at")) ?? now) }
        func checks(_ kind: String) -> [MasteryInput.Check] {
            ((try? db.query("SELECT rating, at FROM topic_checks WHERE topic_id = ? AND kind = ? ORDER BY at", [topicId, kind])) ?? [])
                .map { MasteryInput.Check(rating: $0.str("rating"), at: ISO.parse($0.str("at")) ?? now) }
        }
        let lessonDone = ((try? db.scalarInt("""
            SELECT count(*) FROM study_sessions WHERE topic_id = ? AND kind = 'topic' AND step IN ('practice','explain','lockin','done')
            """, [topicId])) ?? 0) > 0
        let fsrs = FSRS()
        let cards = cards(status: "active").filter { $0.topicId == topicId }
        let r: [Double] = cards.compactMap { c in
            guard let last = c.fsrs.lastReview, c.fsrs.stability > 0 else { return nil }
            return fsrs.retrievability(elapsedDays: max(0, now.timeIntervalSince(last) / 86_400), stability: c.fsrs.stability)
        }
        return MasteryInput(notebookWritten: t.notebookWrittenAt != nil, lessonDone: lessonDone, attempts: attempts, explains: checks("explain"),
                            notebookReviews: checks("notebook_review"), cardRetrievability: r.isEmpty ? nil : r.reduce(0, +) / Double(r.count))
    }

    /// Recomputes a topic's mastery and keeps it on the topic, so the path and the scheduler read it cheaply.
    @discardableResult
    func refreshMastery(topicId: Int, now: Date = Date()) -> Mastery {
        let m = MasteryRules.compute(masteryInput(topicId: topicId, now: now), now: now, tz: timezone)
        if topic(topicId)?.mastery != m {
            _ = try? db.execute("UPDATE path_topics SET mastery = ?, mastery_at = ? WHERE id = ?", [m.rawValue, ISO.instant(now), topicId])
        }
        return m
    }

    /// For housekeeping: cards fade and months pass even when nothing is studied.
    func refreshMastery(courseId: Int, now: Date = Date()) {
        for t in topics(courseId: courseId) where t.mastery != .new { refreshMastery(topicId: t.id, now: now) }
    }
}
