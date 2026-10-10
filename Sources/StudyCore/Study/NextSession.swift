import Foundation

/// The four kinds of study session.
public enum SessionKind: String, Codable, Sendable {
    /// Writing the next pages of the handwritten notebook (definitions and diagrams).
    case notebook
    /// Learning one topic: warm-up, lesson, practice, explain it back, lock in.
    case topic
    /// Flashcards only.
    case review
    /// Before an exam: notebook pages of the exam's topics, then exam-style practice.
    case examPrep = "exam_prep"
}

public enum SessionMode: String, Codable, CaseIterable, Sendable {
    case quick, standard, deep
    public var minutes: Int { self == .quick ? 10 : self == .standard ? 25 : 50 }
    public var label: String { self == .quick ? "Quick" : self == .standard ? "Standard" : "Deep" }
}

/// One session the app suggests, and why.
public struct SessionPick: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        case examIn(days: Int, title: String)
        case taught(LocalDate)
        case nextInPath
        /// Learn this first: the topic it unlocks is on an exam.
        case prereqFor(String)
        case refresh
        case weak
        case notebookFirst
        case cardsDue(Int)
        case unfinished
    }

    public var kind: SessionKind
    public var courseId: Int?
    public var topicId: Int?
    public var unitId: Int?
    public var assignmentId: Int?
    /// Notebook pages to write, or the exam's topics to review, in order.
    public var topicIds: [Int]
    public var reasons: [Reason]
    public var minutes: Int
    public var score: Double
    /// An open session to continue.
    public var sessionId: Int?

    public init(kind: SessionKind, courseId: Int? = nil, topicId: Int? = nil, unitId: Int? = nil, assignmentId: Int? = nil, topicIds: [Int] = [],
                reasons: [Reason] = [], minutes: Int, score: Double, sessionId: Int? = nil) {
        self.kind = kind; self.courseId = courseId; self.topicId = topicId; self.unitId = unitId; self.assignmentId = assignmentId
        self.topicIds = topicIds; self.reasons = reasons; self.minutes = minutes; self.score = score; self.sessionId = sessionId
    }

    public var id: String { "\(kind.rawValue)-\(courseId ?? 0)-\(topicId ?? unitId ?? assignmentId ?? sessionId ?? 0)" }
}

public struct NextSessionInput: Sendable {
    public struct Topic: Sendable {
        public var id: Int
        public var courseId: Int
        public var unitId: Int?
        public var unitOrdinal: Int
        public var ordinal: Int
        public var title: String
        public var mastery: Mastery
        public var prereqIds: [Int]
        public var emphasis: Int
        public var beyondCourse: Bool
        /// The student said they know it, or hid it.
        public var skipped: Bool
        public var notebookWritten: Bool
        /// The topic has a notebook guide to write from.
        public var hasNotebookGuide: Bool
        public var notebookMinutes: Int
        public var estMinutes: Int
        /// When the course first taught it, if its files say.
        public var taughtOn: LocalDate?
        /// Two of the last three practice attempts were missed.
        public var recentlyMissed: Bool
        /// Exam prep found it shaky.
        public var shaky: Bool

        public init(id: Int, courseId: Int, unitId: Int? = nil, unitOrdinal: Int = 1, ordinal: Int, title: String, mastery: Mastery = .new,
                    prereqIds: [Int] = [], emphasis: Int = 1, beyondCourse: Bool = false, skipped: Bool = false, notebookWritten: Bool = false,
                    hasNotebookGuide: Bool = true, notebookMinutes: Int = 5, estMinutes: Int = 25, taughtOn: LocalDate? = nil,
                    recentlyMissed: Bool = false, shaky: Bool = false) {
            self.id = id; self.courseId = courseId; self.unitId = unitId; self.unitOrdinal = unitOrdinal; self.ordinal = ordinal; self.title = title
            self.mastery = mastery; self.prereqIds = prereqIds; self.emphasis = emphasis; self.beyondCourse = beyondCourse; self.skipped = skipped
            self.notebookWritten = notebookWritten; self.hasNotebookGuide = hasNotebookGuide; self.notebookMinutes = notebookMinutes
            self.estMinutes = estMinutes; self.taughtOn = taughtOn; self.recentlyMissed = recentlyMissed; self.shaky = shaky
        }
    }

    public struct Assessment: Sendable {
        public var id: Int
        public var courseId: Int
        public var title: String
        public var due: Date
        public var weightPct: Double?
        /// The topics it covers; empty means every topic taught by its due date.
        public var topicIds: [Int]
        /// Exams and quizzes drive studying; reports and projects are written elsewhere.
        public var isExam: Bool
        /// Topics already reviewed in exam prep for it (shaky ones excluded).
        public var reviewedTopicIds: Set<Int>

        public init(id: Int, courseId: Int, title: String, due: Date, weightPct: Double? = nil, topicIds: [Int] = [], isExam: Bool = true,
                    reviewedTopicIds: Set<Int> = []) {
            self.id = id; self.courseId = courseId; self.title = title; self.due = due; self.weightPct = weightPct; self.topicIds = topicIds
            self.isExam = isExam; self.reviewedTopicIds = reviewedTopicIds
        }
    }

    public var now: Date
    public var tz: TimeZone
    public var topics: [Topic]
    public var assessments: [Assessment]
    public var dueCards: Int
    /// Sessions the student left halfway.
    public var unfinished: [SessionPick]
    public var dailyMinutes: Int
    public var mode: SessionMode

    public init(now: Date, tz: TimeZone, topics: [Topic], assessments: [Assessment] = [], dueCards: Int = 0, unfinished: [SessionPick] = [],
                dailyMinutes: Int = 120, mode: SessionMode = .standard) {
        self.now = now; self.tz = tz; self.topics = topics; self.assessments = assessments; self.dueCards = dueCards
        self.unfinished = unfinished; self.dailyMinutes = dailyMinutes; self.mode = mode
    }
}

public struct NextSessionPlan: Equatable, Sendable {
    public enum Warning: Equatable, Sendable {
        /// The exam's topics won't fit in the study time left before it.
        case tightForExam(assignmentId: Int, title: String, needMinutes: Int, haveMinutes: Int)
        /// Lectures have moved past the student.
        case behindClass(courseId: Int, count: Int)
    }
    public var primary: SessionPick?
    public var then: [SessionPick]
    public var warnings: [Warning]
}

/// What to study now, decided by fixed rules (no AI), so the big Start button is always one tap and always explainable.
public enum NextSession {
    public static func plan(_ i: NextSessionInput) -> NextSessionPlan {
        let today = LocalDate(i.now, tz: i.tz)
        let topics = i.topics.filter { !$0.skipped }
        let byId = Dictionary(uniqueKeysWithValues: i.topics.map { ($0.id, $0) })
        let upcoming = i.assessments.filter { $0.isExam && $0.due > i.now }

        func covers(_ a: NextSessionInput.Assessment, _ t: NextSessionInput.Topic) -> Bool {
            guard a.courseId == t.courseId else { return false }
            if !a.topicIds.isEmpty { return a.topicIds.contains(t.id) }
            // Not mapped: everything taught by then, or (with no teaching dates) the whole course.
            guard let taught = t.taughtOn else { return true }
            return taught <= LocalDate(a.due, tz: i.tz)
        }
        func daysUntil(_ d: Date) -> Int { max(0, today.days(to: LocalDate(d, tz: i.tz))) }
        func examComponent(_ t: NextSessionInput.Topic) -> (Double, NextSessionInput.Assessment?) {
            var best: (Double, NextSessionInput.Assessment?) = (0, nil)
            for a in upcoming where covers(a, t) {
                let days = Double(daysUntil(a.due))
                guard days <= 28 else { continue }
                let w = min(1.5, max(0.5, 0.5 + (a.weightPct ?? 25) / 100))
                let urgency = min(1, max(0.15, (28 - days) / 28))
                let s = 60 * w * urgency
                if s > best.0 { best = (s, a) }
            }
            return best
        }
        func understood(_ id: Int) -> Bool { byId[id].map { $0.mastery.isUnderstood || $0.skipped } ?? true }
        func open(_ t: NextSessionInput.Topic) -> Bool { t.mastery == .new || t.mastery == .familiar }

        // Topics, scored.
        var picks: [SessionPick] = []
        var bestTopicByCourse: [Int: NextSessionInput.Topic] = [:]
        let pathOrder = topics.sorted { ($0.courseId, $0.unitOrdinal, $0.ordinal, $0.id) < ($1.courseId, $1.unitOrdinal, $1.ordinal, $1.id) }
        var orderBonus: [Int: Double] = [:]
        for courseId in Set(topics.map(\.courseId)) {
            let ready = pathOrder.filter { $0.courseId == courseId && open($0) && !$0.beyondCourse && $0.prereqIds.allSatisfy(understood) }
            if let first = ready.first { orderBonus[first.id] = 25 }
            if ready.count > 1 { orderBonus[ready[1].id] = 10 }
        }
        var redirected: [Int: (Double, String, NextSessionInput.Assessment?)] = [:]
        for t in topics where t.mastery != .solid {
            let (exam, examFor) = examComponent(t)
            var reasons: [SessionPick.Reason] = []
            var score = exam
            if let a = examFor { reasons.append(.examIn(days: daysUntil(a.due), title: a.title)) }
            if let taught = t.taughtOn, taught <= today, open(t) {
                score += 20 + min(2 * Double(taught.days(to: today)), 20)
                reasons.append(.taught(taught))
            }
            if let bonus = orderBonus[t.id] { score += bonus; reasons.append(.nextInPath) }
            if t.mastery == .refresh { score += exam > 0 ? 30 : 15; reasons.append(.refresh) }
            if t.recentlyMissed || t.shaky { score += 12; reasons.append(.weak) }
            guard score > 0 else { continue }
            score *= 1 + 0.15 * Double(t.emphasis)
            if t.beyondCourse { score *= 0.5 }
            if !t.notebookWritten && t.hasNotebookGuide { score *= 0.5 }
            let unmet = t.prereqIds.filter { !understood($0) }
            if !unmet.isEmpty {
                if exam > 0, let pre = pathOrder.first(where: { unmet.contains($0.id) && $0.mastery != .solid }) {
                    // Learn what this builds on first; the exam's urgency goes to the prerequisite.
                    let current = redirected[pre.id]?.0 ?? 0
                    if score > current { redirected[pre.id] = (score, t.title, examFor) }
                    continue
                }
                score *= 0.3
            }
            picks.append(SessionPick(kind: .topic, courseId: t.courseId, topicId: t.id, reasons: reasons, minutes: i.mode.minutes, score: score))
        }
        for (preId, (score, title, exam)) in redirected {
            guard let pre = byId[preId] else { continue }
            if let idx = picks.firstIndex(where: { $0.topicId == preId }) {
                if score > picks[idx].score { picks[idx].score = score }
                picks[idx].reasons.append(.prereqFor(title))
            } else {
                var reasons: [SessionPick.Reason] = [.prereqFor(title)]
                if let exam { reasons.insert(.examIn(days: daysUntil(exam.due), title: exam.title), at: 0) }
                picks.append(SessionPick(kind: .topic, courseId: pre.courseId, topicId: preId, reasons: reasons, minutes: i.mode.minutes, score: score))
            }
        }
        for p in picks where p.kind == .topic {
            guard let t = p.topicId.flatMap({ byId[$0] }) else { continue }
            if let best = bestTopicByCourse[t.courseId], (picks.first { $0.topicId == best.id }?.score ?? 0) >= p.score { continue }
            bestTopicByCourse[t.courseId] = t
        }

        // Notebook first: the next unit with pages to write, while the notebook isn't ahead of the studying.
        let pageLimit = i.mode == .quick ? 2 : i.mode == .standard ? 6 : 12
        for courseId in Set(topics.map(\.courseId)) {
            let units = Dictionary(grouping: pathOrder.filter { $0.courseId == courseId && !$0.notebookWritten && $0.hasNotebookGuide && !$0.beyondCourse },
                                   by: { $0.unitOrdinal })
            guard let unitOrdinal = units.keys.min(), let pages = units[unitOrdinal] else { continue }
            let chosen = Array(pages.prefix(pageLimit))
            var score = 45.0
            var reasons: [SessionPick.Reason] = [.notebookFirst]
            if let best = bestTopicByCourse[courseId], !best.notebookWritten { score += 25 }
            let exams = chosen.map { examComponent($0) }
            if let top = exams.max(by: { $0.0 < $1.0 }), top.0 > 0, let a = top.1 {
                score += top.0
                reasons.append(.examIn(days: daysUntil(a.due), title: a.title))
            }
            picks.append(SessionPick(kind: .notebook, courseId: courseId, unitId: chosen.first?.unitId, topicIds: chosen.map(\.id), reasons: reasons,
                                     minutes: max(5, chosen.reduce(0) { $0 + $1.notebookMinutes }), score: score))
        }

        // Exam prep in the last two weeks: the exam's notebook pages, then exam-style practice. It reviews what has been
        // learned; topics not learned yet get the exam's urgency as topic sessions instead.
        for a in upcoming where daysUntil(a.due) <= 14 {
            let mine = topics.filter { covers(a, $0) && $0.notebookWritten && $0.mastery.isUnderstood }
            guard !mine.isEmpty else { continue }
            let ordered = mine.sorted { x, y in
                let xr = a.reviewedTopicIds.contains(x.id), yr = a.reviewedTopicIds.contains(y.id)
                if xr != yr { return !xr }
                if x.shaky != y.shaky { return x.shaky }
                if x.emphasis != y.emphasis { return x.emphasis > y.emphasis }
                return (x.unitOrdinal, x.ordinal) < (y.unitOrdinal, y.ordinal)
            }
            let reviewCount = i.mode == .quick ? 3 : i.mode == .standard ? 6 : 10
            let w = min(1.5, max(0.5, 0.5 + (a.weightPct ?? 25) / 100))
            let urgency = min(1, max(0.15, Double(28 - daysUntil(a.due)) / 28))
            picks.append(SessionPick(kind: .examPrep, courseId: a.courseId, assignmentId: a.id, topicIds: Array(ordered.prefix(reviewCount).map(\.id)),
                                     reasons: [.examIn(days: daysUntil(a.due), title: a.title)], minutes: i.mode.minutes,
                                     score: 55 + 60 * w * urgency))
        }

        // Flashcards.
        if i.dueCards >= 20 {
            picks.append(SessionPick(kind: .review, reasons: [.cardsDue(i.dueCards)], minutes: max(5, i.dueCards * 20 / 60),
                                     score: i.dueCards >= 40 ? 50 : 30))
        }

        // Highest score first; ties: the nearer exam, then path position.
        func examDays(_ p: SessionPick) -> Int {
            p.reasons.compactMap { if case .examIn(let d, _) = $0 { return d }; return nil }.min() ?? .max
        }
        func position(_ p: SessionPick) -> (Int, Int, Int, Int) {
            let t = (p.topicId ?? p.topicIds.first).flatMap { byId[$0] }
            return (p.courseId ?? 0, t?.unitOrdinal ?? 0, t?.ordinal ?? 0, t?.id ?? 0)
        }
        picks.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if examDays(a) != examDays(b) { return examDays(a) < examDays(b) }
            return position(a) < position(b)
        }
        // Work that's already open is offered as Continue only, never again as a new session beside it.
        func work(_ p: SessionPick) -> String { "\(p.kind.rawValue)-\(p.courseId ?? 0)-\(p.topicId ?? 0)-\(p.assignmentId ?? 0)" }
        var open = Set<String>()
        let unfinished = i.unfinished.filter { open.insert(work($0)).inserted }
            .map { var p = $0; p.reasons = [.unfinished] + p.reasons; p.score = .infinity; return p }
        var ordered = unfinished + picks.filter { !open.contains(work($0)) }
        var primary = ordered.isEmpty ? nil : ordered.removeFirst()
        if primary?.score == 0 { primary = nil }
        var then: [SessionPick] = []
        if let next = ordered.first { then.append(next); ordered.removeFirst() }
        // The third suggestion comes from another course when it's nearly as urgent.
        if let top = primary, let other = ordered.first(where: { $0.courseId != top.courseId && $0.courseId != then.first?.courseId && $0.score >= 0.6 * top.score && top.score.isFinite }) {
            then.append(other)
        } else if let next = ordered.first {
            then.append(next)
        }

        return NextSessionPlan(primary: primary, then: then, warnings: warnings(i, topics: topics, covers: covers, today: today))
    }

    /// Exams whose topics won't fit in the study time left (earliest first, adding up), and lectures that moved past.
    static func warnings(_ i: NextSessionInput, topics: [NextSessionInput.Topic], covers: (NextSessionInput.Assessment, NextSessionInput.Topic) -> Bool,
                         today: LocalDate) -> [NextSessionPlan.Warning] {
        var out: [NextSessionPlan.Warning] = []
        var need = 0.0
        var counted = Set<Int>()
        for a in i.assessments.filter({ $0.isExam && $0.due > i.now }).sorted(by: { $0.due < $1.due }) {
            let days = today.days(to: LocalDate(a.due, tz: i.tz))
            guard days <= 28 else { continue }
            for t in topics where covers(a, t) && !counted.contains(t.id) {
                counted.insert(t.id)
                let notebook = t.notebookWritten || !t.hasNotebookGuide ? 0 : Double(t.notebookMinutes)
                switch t.mastery {
                case .new, .familiar: need += Double(t.estMinutes) + notebook
                case .learning: need += 0.6 * Double(t.estMinutes) + notebook
                case .practiced, .refresh: need += 0.3 * Double(t.estMinutes)
                case .solid: break
                }
            }
            let have = Double(max(0, days) * i.dailyMinutes)
            if need > 0.85 * have {
                out.append(.tightForExam(assignmentId: a.id, title: a.title, needMinutes: Int(need.rounded()), haveMinutes: Int(have)))
            }
        }
        for courseId in Set(topics.map(\.courseId)).sorted() {
            let behind = topics.filter { $0.courseId == courseId && ($0.mastery == .new || $0.mastery == .familiar) && ($0.taughtOn.map { $0.days(to: today) >= 2 } ?? false) }
            if behind.count >= 2 { out.append(.behindClass(courseId: courseId, count: behind.count)) }
        }
        return out
    }
}
