import Foundation

/// One course on Home: how much of its notebook is written and how much of its path is understood.
public struct CourseProgress: Identifiable {
    public var course: Course
    public var topics: Int
    public var written: Int
    public var solid: Int
    public var nextExam: Assignment?
    /// Topics taught in class that the student hasn't started.
    public var behind: Int
    public var pathTier: String?
    public var id: Int { course.id }
}

/// Everything Home shows, in one read.
public struct HomeSnapshot {
    public var plan: NextSessionPlan
    /// Overdue or at-risk graded work.
    public var urgent: SuggestedAction?
    public var courses: [CourseProgress]
    public var dueThisWeek: [Assignment]
    public var needsLook: Int
    public var cardsDue: Int
}

public extension StudyStore {
    func homeSnapshot(now: Date = Date()) -> HomeSnapshot {
        let tz = timezone
        let today = LocalDate(now, tz: tz)
        let all = assignments()
        let busy = busyIntervals(from: now, to: now.adding(days: 15))
        let settings = plannerSettings
        let blocks = studyBlocks(from: now.adding(days: -1), to: now.adding(days: 30), statuses: ["planned", "done"])
        let inputs = TodayInputs(now: now, assignments: all, plannedBlockAssignmentIds: Set(blocks.compactMap(\.assignmentId)), cardsDue: dueCount(now: now),
                                 proposedCards: 0, readyUnprocessed: [], processedWithoutRecall: [], nextClassTitle: nil,
                                 freeHoursUntil: { due in StudyPlanner.freeHours(until: due, busy: busy, settings: settings, now: now, tz: tz) })
        let courses = coursesToBuild(now: now).map { c -> CourseProgress in
            let topics = self.topics(courseId: c.id).filter { $0.userState != "hidden" }
            let taught = taughtDates(courseId: c.id)
            let exam = all.filter { $0.courseId == c.id && $0.kind == .exam && $0.isOpen && ($0.dueAt ?? .distantPast) > now }
                .min { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            let behind = topics.filter { t in taught[t.id].map { $0 < today } ?? false && !t.mastery.isUnderstood && !t.isSkipped }.count
            return CourseProgress(course: c, topics: topics.count, written: topics.filter(\.inNotebook).count,
                                  solid: topics.filter { $0.mastery == .solid }.count, nextExam: exam, behind: behind, pathTier: path(courseId: c.id)?.tier)
        }
        let weekEnd = now.adding(days: 7)
        let due = all.filter { a in a.isOpen && a.confirmed && (a.dueAt.map { $0 > now && $0 <= weekEnd } ?? false) }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        return HomeSnapshot(plan: nextSessionPlan(now: now), urgent: TodayRules.urgent(inputs), courses: courses, dueThisWeek: due,
                            needsLook: needsLookCount(), cardsDue: dueCount(now: now))
    }
}
