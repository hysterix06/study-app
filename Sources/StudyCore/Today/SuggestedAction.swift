import Foundation

public struct SuggestedAction: Equatable {
    public enum Kind: String { case finishOverdue, startAtRisk, keepGoing, planExam, review, approveCards, process, recall, nothing }
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var assignmentId: Int?
    public var materialId: Int?
    public var count: Int?
}

public struct TodayInputs {
    public var now: Date
    public var assignments: [Assignment]           // confirmed
    public var weightDefault: Double = 5
    public var plannedBlockAssignmentIds: Set<Int>
    public var cardsDue: Int
    public var proposedCards: Int
    public var readyUnprocessed: [Material]        // filed lectures with no processing yet
    public var processedWithoutRecall: [Material]  // processed >24h ago, no recall-type session since
    public var nextClassTitle: String?
    /// Free study hours between now and a date.
    public var freeHoursUntil: (Date) -> Double

    public init(now: Date, assignments: [Assignment], plannedBlockAssignmentIds: Set<Int>, cardsDue: Int, proposedCards: Int,
                readyUnprocessed: [Material], processedWithoutRecall: [Material], nextClassTitle: String?, freeHoursUntil: @escaping (Date) -> Double) {
        self.now = now; self.assignments = assignments; self.plannedBlockAssignmentIds = plannedBlockAssignmentIds
        self.cardsDue = cardsDue; self.proposedCards = proposedCards; self.readyUnprocessed = readyUnprocessed
        self.processedWithoutRecall = processedWithoutRecall; self.nextClassTitle = nextClassTitle; self.freeHoursUntil = freeHoursUntil
    }
}

/// Exactly one suggested action, chosen by ordered rules (first match wins). Within a rule, items are
/// ranked by impact — weight × time pressure — rather than by due date alone.
public enum TodayRules {
    public static func suggest(_ i: TodayInputs) -> SuggestedAction {
        let open = i.assignments.filter { $0.confirmed && $0.isOpen }

        // 1. Overdue, unsubmitted: the heaviest first.
        let overdue = open.filter { $0.isOverdue(now: i.now) }
            .sorted { (($0.weightPct ?? i.weightDefault), $1.dueAt!) > (($1.weightPct ?? i.weightDefault), $0.dueAt!) }
        if let a = overdue.first {
            return SuggestedAction(kind: .finishOverdue, title: "Finish: \(a.title) (overdue)", detail: weightDetail(a), assignmentId: a.id)
        }

        // 2. At-risk work in the next 14 days: pressure = hours still needed ÷ free hours before the deadline.
        struct Risk { var a: Assignment; var pressure: Double; var score: Double }
        var risks: [Risk] = []
        for a in open {
            guard let due = a.dueAt, due > i.now, due.timeIntervalSince(i.now) <= 14 * 86400, a.kind != .exam else { continue }
            let remaining = a.hoursNeeded * (a.status == .inProgress ? 0.5 : 1)
            let free = max(i.freeHoursUntil(due), 0.25)
            let pressure = remaining / free
            let within48 = due.timeIntervalSince(i.now) <= 48 * 3600
            let atRisk = pressure >= 0.5 || (within48 && a.status == .notStarted)
            if atRisk { risks.append(Risk(a: a, pressure: pressure, score: (a.weightPct ?? i.weightDefault) * min(pressure, 3) + (within48 ? 50 : 0))) }
        }
        if let r = risks.max(by: { ($0.score, -$0.a.dueAt!.timeIntervalSince1970) < ($1.score, -$1.a.dueAt!.timeIntervalSince1970) }) {
            let verb = r.a.status == .notStarted ? "Start" : "Keep going"
            return SuggestedAction(kind: r.a.status == .notStarted ? .startAtRisk : .keepGoing, title: "\(verb): \(r.a.title)",
                                   detail: [weightDetail(r.a), String(format: "needs ~%.1f h, %.0f%% of your free time before it's due", r.a.hoursNeeded, min(r.pressure, 9.99) * 100)]
                                    .compactMap { $0 }.joined(separator: " · "),
                                   assignmentId: r.a.id)
        }

        // 3. Exam within 14 days without planned study (spacing needs lead time; 7 days is too late).
        let exams = open.filter { a in
            guard a.kind == .exam, let due = a.dueAt else { return false }
            return due > i.now && due.timeIntervalSince(i.now) <= 14 * 86400 && !i.plannedBlockAssignmentIds.contains(a.id)
        }.sorted { $0.dueAt! < $1.dueAt! }
        if let e = exams.first {
            return SuggestedAction(kind: .planExam, title: "Plan study for \(e.title)", detail: weightDetail(e), assignmentId: e.id)
        }

        // 4. Reviews.
        if i.cardsDue >= 5 {
            let minutes = max(1, Int((Double(i.cardsDue) * 20 / 60).rounded()))
            return SuggestedAction(kind: .review, title: "Review \(i.cardsDue) cards (about \(minutes) min)", count: i.cardsDue)
        }

        // 5. Recall a processed lecture before it fades (retrieval within ~48 h).
        if let m = i.processedWithoutRecall.first {
            return SuggestedAction(kind: .recall, title: "Recall: \(m.title)", detail: "Write what you remember before looking.", materialId: m.id)
        }

        // 6. Process a ready lecture.
        if let m = i.readyUnprocessed.first {
            return SuggestedAction(kind: .process, title: "Process \(m.title)", materialId: m.id)
        }

        // 7. Approve proposed cards.
        if i.proposedCards > 0 {
            return SuggestedAction(kind: .approveCards, title: "Approve or rewrite \(i.proposedCards) proposed card\(i.proposedCards == 1 ? "" : "s")", count: i.proposedCards)
        }

        return SuggestedAction(kind: .nothing, title: "Nothing urgent." + (i.nextClassTitle.map { " Next class: \($0)." } ?? ""))
    }

    static func weightDetail(_ a: Assignment) -> String? {
        a.weightPct.map { String(format: "%g%% of the final grade", $0) }
    }
}
