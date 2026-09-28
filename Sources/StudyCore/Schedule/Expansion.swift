import Foundation

public struct Occurrence: Identifiable, Hashable {
    public enum Origin: Hashable {
        case pattern(patternId: Int, originalDate: LocalDate)
        case event(eventId: Int)
    }
    public enum Status: String { case normal, modified, canceled }

    public var key: String
    public var id: String { key }
    public var courseId: Int?
    public var title: String
    public var kind: String // class | event | busy
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String?
    public var origin: Origin
    public var status: Status
    public var note: String?

    public var isClass: Bool { kind == "class" }
    public var patternId: Int? { if case .pattern(let id, _) = origin { return id }; return nil }
    public var originalDate: LocalDate? { if case .pattern(_, let d) = origin { return d }; return nil }
    public var eventId: Int? { if case .event(let id) = origin { return id }; return nil }

    public func asJSON(tz: TimeZone, courses: [Int: Course]) -> [String: Any] {
        var d: [String: Any] = [
            "key": key, "title": title, "kind": kind,
            "start": ISO.instant(start, in: tz), "end": ISO.instant(end, in: tz),
            "status": status.rawValue, "all_day": allDay,
        ]
        if let courseId { d["course_id"] = courseId; d["course"] = courses[courseId]?.shortName ?? "" }
        if let location { d["location"] = location }
        if let note { d["note"] = note }
        switch origin {
        case .pattern(let pid, let od): d["origin"] = ["type": "pattern", "pattern_id": pid, "original_date": od.string]
        case .event(let eid): d["origin"] = ["type": "event", "event_id": eid]
        }
        return d
    }
}

public enum ScheduleEngine {
    /// Expands weekly patterns, exceptions, breaks and one-off events into concrete occurrences (§5.1).
    /// `range` dates are inclusive and interpreted in `displayTimezone`.
    public static func expand(
        from: LocalDate, to: LocalDate,
        patterns: [ClassPattern], exceptions: [ClassException], events: [Event], breaks: [TermBreak],
        courses: [Int: Course], displayTimezone: TimeZone
    ) -> [Occurrence] {
        var out: [Occurrence] = []
        let rangeStart = from.at(LocalTime(hour: 0, minute: 0), tz: displayTimezone)
        let rangeEnd = to.adding(days: 1).at(LocalTime(hour: 0, minute: 0), tz: displayTimezone)
        func inRange(_ start: Date) -> Bool { start >= rangeStart && start < rangeEnd }

        let exByPattern = Dictionary(grouping: exceptions, by: { $0.patternId })

        for p in patterns {
            let tz = p.tz
            let course = courses[p.courseId]
            let title = course.map { c in c.code.map { "\(c.name) (\($0))" } ?? c.name } ?? "Class"
            let exs = exByPattern[p.id] ?? []
            var handled = Set<LocalDate>()

            for ex in exs {
                // Only exceptions that line up with a real occurrence of this pattern.
                guard ex.originalDate.weekday == p.weekday, ex.originalDate >= p.validFrom, ex.originalDate <= p.validTo else { continue }
                handled.insert(ex.originalDate)
                switch ex.kind {
                case .cancel:
                    let start = ex.originalDate.at(p.startTime, tz: tz)
                    guard inRange(start) else { continue }
                    out.append(Occurrence(
                        key: "p\(p.id):\(ex.originalDate.string)", courseId: p.courseId, title: title, kind: "class",
                        start: start, end: ex.originalDate.at(p.endTime, tz: tz), allDay: false, location: p.location,
                        origin: .pattern(patternId: p.id, originalDate: ex.originalDate), status: .canceled, note: ex.note))
                case .modify:
                    let date = ex.newDate ?? ex.originalDate
                    let st = ex.newStartTime ?? p.startTime
                    let et = ex.newEndTime ?? p.endTime
                    let start = date.at(st, tz: tz)
                    guard inRange(start) else { continue }
                    var end = date.at(et, tz: tz)
                    if end <= start { end = start.adding(minutes: max(p.endTime.minutes - p.startTime.minutes, 30)) }
                    out.append(Occurrence(
                        key: "p\(p.id):\(ex.originalDate.string)", courseId: p.courseId, title: title, kind: "class",
                        start: start, end: end, allDay: false, location: ex.newLocation ?? p.location,
                        origin: .pattern(patternId: p.id, originalDate: ex.originalDate), status: .modified, note: ex.note))
                }
            }

            // Pattern dates are in the pattern's zone; widen by a day so zone differences at the edges are covered.
            let lo = max(p.validFrom, from.adding(days: -1))
            let hi = min(p.validTo, to.adding(days: 1))
            guard lo <= hi else { continue }
            var d = lo
            let shift = (p.weekday - d.weekday + 7) % 7
            d = d.adding(days: shift)
            while d <= hi {
                defer { d = d.adding(days: 7) }
                if handled.contains(d) { continue }
                if breaks.contains(where: { $0.contains(d) }) { continue }
                let start = d.at(p.startTime, tz: tz)
                guard inRange(start) else { continue }
                var end = d.at(p.endTime, tz: tz)
                if end <= start { end = start.adding(minutes: 60) }
                out.append(Occurrence(
                    key: "p\(p.id):\(d.string)", courseId: p.courseId, title: title, kind: "class",
                    start: start, end: end, allDay: false, location: p.location,
                    origin: .pattern(patternId: p.id, originalDate: d), status: .normal, note: nil))
            }
        }

        for e in events {
            let start = e.start
            if e.allDay {
                let day = LocalDate(start, tz: TimeZone(identifier: "UTC")!)
                guard day >= from && day <= to else { continue }
                let s = day.at(LocalTime(hour: 0, minute: 0), tz: displayTimezone)
                out.append(Occurrence(
                    key: "e\(e.id)", courseId: e.courseId, title: e.title, kind: e.kind, start: s,
                    end: s.adding(days: 1), allDay: true, location: e.location, origin: .event(eventId: e.id),
                    status: e.canceled ? .canceled : (e.userModified ? .modified : .normal), note: e.notes))
                continue
            }
            guard inRange(start) else { continue }
            out.append(Occurrence(
                key: "e\(e.id)", courseId: e.courseId, title: e.title, kind: e.kind, start: start,
                end: e.end ?? start.adding(minutes: 60), allDay: false, location: e.location, origin: .event(eventId: e.id),
                status: e.canceled ? .canceled : (e.userModified && e.source != "manual" ? .modified : .normal), note: e.notes))
        }

        return out.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
    }
}
