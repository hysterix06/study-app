import Foundation

public extension StudyStore {
    /// The study minutes a day the student has, for "will this fit before the exam?" (from the planner's daily cap).
    var dailyStudyMinutes: Int { plannerSettings.maxMinutesPerDay }

    /// Everything the scheduler needs, from the database.
    func nextSessionInput(now: Date = Date(), mode: SessionMode = .standard) -> NextSessionInput {
        let tz = timezone
        var topics: [NextSessionInput.Topic] = []
        for course in courses() {
            let units = Dictionary(uniqueKeysWithValues: units(courseId: course.id).map { ($0.id, $0.ordinal) })
            let guides = notebooks(courseId: course.id)
            let taught = taughtDates(courseId: course.id)
            let misses = recentlyMissedTopics(courseId: course.id)
            let shaky = shakyTopics(courseId: course.id)
            for t in self.topics(courseId: course.id) {
                topics.append(NextSessionInput.Topic(
                    id: t.id, courseId: course.id, unitId: t.unitId, unitOrdinal: t.unitId.flatMap { units[$0] } ?? 999, ordinal: t.ordinal,
                    title: t.title, mastery: t.mastery, prereqIds: t.prereqIds, emphasis: t.emphasis, beyondCourse: t.beyondCourse,
                    skipped: t.isSkipped, notebookWritten: t.inNotebook, hasNotebookGuide: guides[t.id] != nil,
                    notebookMinutes: guides[t.id]?.writingMinutes ?? 5, estMinutes: t.estMinutes, taughtOn: taught[t.id],
                    recentlyMissed: misses.contains(t.id), shaky: shaky.contains(t.id)))
            }
        }
        let exams = assignments(AssignmentFilter(statuses: [.notStarted, .inProgress])).compactMap { a -> NextSessionInput.Assessment? in
            guard let courseId = a.courseId, let due = a.dueAt, due > now else { return nil }
            return NextSessionInput.Assessment(id: a.id, courseId: courseId, title: a.title, due: due, weightPct: a.weightPct,
                                               topicIds: assessmentTopicIds(assignmentId: a.id), isExam: a.kind == .exam || a.kind == .quiz,
                                               reviewedTopicIds: reviewedInExamPrep(assignmentId: a.id))
        }
        return NextSessionInput(now: now, tz: tz, topics: topics, assessments: exams, dueCards: dueCount(now: now),
                                unfinished: unfinishedSessions().compactMap(\.pick), dailyMinutes: dailyStudyMinutes, mode: mode)
    }

    func nextSessionPlan(now: Date = Date(), mode: SessionMode = .standard) -> NextSessionPlan {
        NextSession.plan(nextSessionInput(now: now, mode: mode))
    }

    /// The same rules, for one course: what its page suggests.
    func nextSessionPlan(courseId: Int, now: Date = Date(), mode: SessionMode = .standard) -> NextSessionPlan {
        var input = nextSessionInput(now: now, mode: mode)
        input.topics = input.topics.filter { $0.courseId == courseId }
        input.assessments = input.assessments.filter { $0.courseId == courseId }
        input.unfinished = input.unfinished.filter { $0.courseId == courseId }
        input.dueCards = (try? db.scalarInt("SELECT count(*) FROM cards WHERE status = 'active' AND course_id = ? AND due <= ?",
                                            [courseId, ISO.instant(now)])) ?? 0
        return NextSession.plan(input)
    }

    /// When the course first taught each topic: the earliest teaching date of the files that cover it.
    func taughtDates(courseId: Int) -> [Int: LocalDate] {
        let rows = (try? db.query("""
            SELECT c.topic_id, min(m.taught_on) AS taught FROM topic_coverage c JOIN materials m ON m.id = c.material_id
            JOIN path_topics t ON t.id = c.topic_id
            WHERE t.course_id = ? AND m.taught_on IS NOT NULL AND m.excluded = 0 GROUP BY c.topic_id
            """, [courseId])) ?? []
        return Dictionary(rows.compactMap { r in LocalDate(r.str("taught")).map { (r.i("topic_id"), $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Topics where two of the last three practice attempts were missed.
    func recentlyMissedTopics(courseId: Int) -> Set<Int> {
        let rows = (try? db.query("""
            SELECT p.topic_id, a.self_rating FROM practice_attempts a JOIN practice_items p ON p.id = a.item_id
            WHERE p.course_id = ? AND p.topic_id IS NOT NULL ORDER BY a.attempted_at DESC
            """, [courseId])) ?? []
        var recent: [Int: [String]] = [:]
        for r in rows where (recent[r.i("topic_id")]?.count ?? 0) < 3 { recent[r.i("topic_id"), default: []].append(r.str("self_rating")) }
        return Set(recent.filter { $0.value.filter { $0 == "missed" }.count >= 2 }.keys)
    }

    /// Topics whose latest exam-prep check was "shaky".
    func shakyTopics(courseId: Int) -> Set<Int> {
        let rows = (try? db.query("""
            SELECT c.topic_id, c.rating FROM topic_checks c JOIN path_topics t ON t.id = c.topic_id
            WHERE t.course_id = ? AND c.kind = 'notebook_review' ORDER BY c.at
            """, [courseId])) ?? []
        var last: [Int: String] = [:]
        for r in rows { last[r.i("topic_id")] = r.str("rating") }
        return Set(last.filter { $0.value == "shaky" }.keys)
    }

    /// Topics already reviewed in exam prep for this exam (and not found shaky since), so the next prep moves on.
    func reviewedInExamPrep(assignmentId: Int) -> Set<Int> {
        let rows = (try? db.query("""
            SELECT c.topic_id, c.rating FROM topic_checks c JOIN study_sessions s ON s.id = c.session_id
            WHERE s.assignment_id = ? AND s.kind = 'exam_prep' AND c.kind = 'notebook_review' ORDER BY c.at
            """, [assignmentId])) ?? []
        var last: [Int: String] = [:]
        for r in rows { last[r.i("topic_id")] = r.str("rating") }
        return Set(last.filter { $0.value == "solid" }.keys)
    }

    /// Notebook, topic and exam-prep sessions the student left halfway, newest first.
    func unfinishedSessions(limit: Int = 3) -> [StudySession] {
        ((try? db.query("""
            SELECT * FROM study_sessions WHERE ended_at IS NULL AND kind IN ('notebook','topic','exam_prep','review')
              AND started_at > ? ORDER BY started_at DESC LIMIT ?
            """, [ISO.instant(Date().adding(days: -7)), limit])) ?? []).map(StudySession.init)
    }
}

extension StudySession {
    /// An unfinished session as a suggestion to continue it.
    var pick: SessionPick? {
        guard let k = SessionKind(rawValue: kind) else { return nil }
        let ids = (JSON.parse(progressJson) as? [String: Any])?["topic_ids"] as? [Int] ?? []
        return SessionPick(kind: k, courseId: courseId, topicId: topicId, assignmentId: assignmentId, topicIds: ids,
                           minutes: SessionMode(rawValue: mode ?? "")?.minutes ?? 25, score: 1, sessionId: id)
    }
}
