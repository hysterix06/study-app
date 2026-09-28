import Foundation

public struct TodaySnapshot {
    public var now: Date
    public var nextClass: Occurrence?
    public var today: [Occurrence]
    public var dueSoon: [Assignment]
    public var suggested: SuggestedAction
    public var cardsDue: Int
    public var inboxCount: Int
    public var openSession: StudySession?
    public var unprocessed: [Material]
    public var proposedPending: Int
}

public struct Outcomes {
    public var missedDeadlines: [Assignment]
    public var onTimeRate: Double?
    public var retention30d: Double?
    public var reviews30d: Int
    public var processedLectures: Int
    public var recalledWithin48h: Int
    public var minutesByWeek: [(weekStart: LocalDate, minutes: Int)]
    public var sessionsByKind: [String: Int]
    public var gradeByCourse: [(course: Course, summary: GradeSummary)]
    public var weakConcepts: [(concept: Concept, count: Int)]

    public func asJSON() -> [String: Any] {
        [
            "missed_deadlines": missedDeadlines.map { ["id": $0.id, "title": $0.title, "due_at": $0.dueAt.map { ISO.instant($0) } as Any] },
            "on_time_rate": onTimeRate as Any,
            "retention_30d": retention30d as Any,
            "reviews_30d": reviews30d,
            "processed_lectures": processedLectures,
            "recalled_within_48h": recalledWithin48h,
            "study_minutes_by_week": minutesByWeek.map { ["week_start": $0.weekStart.string, "minutes": $0.minutes] },
            "sessions_by_kind": sessionsByKind,
            "grades": gradeByCourse.map { ["course": $0.course.shortName, "course_id": $0.course.id, "summary": $0.summary.asJSON()] },
            "weak_concepts": weakConcepts.prefix(10).map { ["name": $0.concept.name, "times_flagged": $0.count, "course_id": $0.concept.courseId] },
        ]
    }
}

public extension StudyStore {
    func busyIntervals(from: Date, to: Date) -> [(start: Date, end: Date)] {
        let tz = timezone
        let occ = occurrences(from: LocalDate(from, tz: tz), to: LocalDate(to, tz: tz))
        return occ.filter { $0.status != .canceled && !$0.allDay }.map { ($0.start, $0.end) }
    }

    func inboxCount() -> Int {
        let files = (try? db.scalarInt("SELECT count(*) FROM materials WHERE status IN ('inbox','failed','needs_ocr') AND course_id IS NULL")) ?? 0
        let failed = (try? db.scalarInt("SELECT count(*) FROM materials WHERE status IN ('failed','needs_ocr') AND course_id IS NOT NULL")) ?? 0
        let ready = (try? db.scalarInt("SELECT count(*) FROM materials WHERE status = 'ready' AND processed_at IS NULL AND role IN ('lecture','reading')")) ?? 0
        let proposed = (try? db.scalarInt("SELECT count(*) FROM assignments WHERE confirmed = 0 AND dismissed = 0")) ?? 0
        let blocks = (try? db.scalarInt("SELECT count(*) FROM study_blocks WHERE status = 'proposed' AND created_by = 'claude'")) ?? 0
        return files + failed + ready + proposed + blocks + conflicts().count + proposedCardCount()
    }

    func processedWithoutRecall(now: Date = Date()) -> [Material] {
        let rows = (try? db.query("""
            SELECT m.* FROM materials m
            WHERE m.processed_at IS NOT NULL AND m.processed_at <= ? AND m.processed_at >= ?
              AND NOT EXISTS (SELECT 1 FROM study_sessions s WHERE s.material_id = m.id
                              AND s.kind IN ('recall','feynman','quiz','handwriting') AND s.started_at >= m.processed_at)
            ORDER BY m.processed_at
            """, [ISO.instant(now.adding(hours: -12)), ISO.instant(now.adding(days: -10))])) ?? []
        return rows.map(Material.init)
    }

    func todaySnapshot(now: Date = Date()) -> TodaySnapshot {
        let tz = timezone
        let today = LocalDate(now, tz: tz)
        let occ = occurrences(from: today, to: today.adding(days: 14), includeBusy: false)
        let nextClass = occ.first { $0.isClass && $0.status != .canceled && $0.end > now }
        let todayOcc = occ.filter { LocalDate($0.start, tz: tz) == today && $0.kind != "busy" }
        let all = assignments()
        let due7 = all.filter { a in
            guard a.isOpen, let d = a.dueAt else { return false }
            return d <= now.adding(days: 7)
        }
        let settings = plannerSettings
        let busy = busyIntervals(from: now, to: now.adding(days: 15))
        let blocks = studyBlocks(from: now.adding(days: -1), to: now.adding(days: 30), statuses: ["planned", "done"])
        let unprocessed = materials(statuses: ["ready"], processed: false).filter { $0.role == .lecture || $0.role == .reading }
        let cardsDue = dueCount(now: now)
        let inputs = TodayInputs(
            now: now, assignments: all, plannedBlockAssignmentIds: Set(blocks.compactMap(\.assignmentId)),
            cardsDue: cardsDue, proposedCards: proposedCardCount(), readyUnprocessed: unprocessed,
            processedWithoutRecall: processedWithoutRecall(now: now), nextClassTitle: nextClass?.title,
            freeHoursUntil: { due in StudyPlanner.freeHours(until: due, busy: busy, settings: settings, now: now, tz: tz) })
        return TodaySnapshot(now: now, nextClass: nextClass, today: todayOcc, dueSoon: due7, suggested: TodayRules.suggest(inputs),
                             cardsDue: cardsDue, inboxCount: inboxCount(), openSession: openSession(), unprocessed: unprocessed,
                             proposedPending: (try? db.scalarInt("SELECT count(*) FROM assignments WHERE confirmed = 0 AND dismissed = 0")) ?? 0)
    }

    func gradeSummary(courseId: Int) throws -> GradeSummary {
        guard let c = course(courseId) else { throw ToolError.notFound("Course \(courseId) does not exist.") }
        return try GradeMath.summarize(assignments: assignments(AssignmentFilter(courseId: courseId)), target: c.targetGrade, scale: c.gradeScale)
    }

    /// Outcome measures, so the student can tell whether the system is working.
    func outcomes(now: Date = Date()) -> Outcomes {
        let tz = timezone
        let term = currentTerm()
        let termStart = term.map { $0.startDate.at(LocalTime(hour: 0, minute: 0), tz: tz) } ?? now.adding(days: -120)
        let pastDue = assignments(AssignmentFilter(dueFrom: termStart, dueTo: now)).filter { $0.kind != .reading }
        let missed = pastDue.filter { a in
            if a.isOpen { return true }
            if let s = a.submittedAt, let d = a.dueAt { return s > d.adding(minutes: 5) }
            return false
        }
        let onTime = pastDue.isEmpty ? nil : Double(pastDue.count - missed.count) / Double(pastDue.count)

        let since = ISO.instant(now.adding(days: -30))
        let reviewRows = (try? db.query("SELECT rating, state_before FROM card_reviews WHERE reviewed_at >= ?", [since])) ?? []
        let matured = reviewRows.filter { $0.i("state_before") == CardState.review.rawValue }
        let retention = matured.isEmpty ? nil : Double(matured.filter { $0.i("rating") >= 2 }.count) / Double(matured.count)

        let processed = materials(processed: true)
        var recalled = 0
        let allSessions = sessions(limit: 2000)
        for m in processed {
            guard let p = m.processedAt else { continue }
            if allSessions.contains(where: { $0.materialId == m.id && ["recall", "feynman", "quiz", "handwriting"].contains($0.kind)
                && $0.startedAt >= p && $0.startedAt <= p.adding(hours: 48) }) { recalled += 1 }
        }

        var weeks: [LocalDate: Int] = [:]
        let thisWeek = LocalDate(now, tz: tz).startOfWeek(weekStartsOn: weekStartsOn)
        for w in 0..<8 { weeks[thisWeek.adding(days: -7 * w)] = 0 }
        for s in allSessions {
            let wk = LocalDate(s.startedAt, tz: tz).startOfWeek(weekStartsOn: weekStartsOn)
            guard weeks[wk] != nil else { continue }
            let mins = s.endedAt.map { max(0, Int($0.timeIntervalSince(s.startedAt) / 60)) } ?? 0
            weeks[wk]! += min(mins, 240)
        }
        for b in studyBlocks(from: now.adding(days: -60), to: now, statuses: ["done"]) {
            let wk = LocalDate(b.plannedStart, tz: tz).startOfWeek(weekStartsOn: weekStartsOn)
            if weeks[wk] != nil { weeks[wk]! += b.plannedMinutes }
        }
        let reviewMs = (try? db.query("SELECT reviewed_at, duration_ms FROM card_reviews WHERE reviewed_at >= ?", [ISO.instant(now.adding(days: -60))])) ?? []
        for r in reviewMs {
            guard let d = ISO.parse(r.str("reviewed_at")) else { continue }
            let wk = LocalDate(d, tz: tz).startOfWeek(weekStartsOn: weekStartsOn)
            if weeks[wk] != nil { weeks[wk]! += min(r.i("duration_ms"), 120_000) / 60_000 }
        }

        var byKind: [String: Int] = [:]
        for s in allSessions { byKind[s.kind, default: 0] += 1 }
        let grades = courses().compactMap { c -> (Course, GradeSummary)? in
            guard let g = try? gradeSummary(courseId: c.id), g.totalWeight > 0 else { return nil }
            return (c, g)
        }
        return Outcomes(missedDeadlines: missed, onTimeRate: onTime, retention30d: retention, reviews30d: reviewRows.count,
                        processedLectures: processed.count, recalledWithin48h: recalled,
                        minutesByWeek: weeks.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, sessionsByKind: byKind,
                        gradeByCourse: grades, weakConcepts: weakConcepts(now: now))
    }
}
