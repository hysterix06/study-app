import Foundation

public enum EditScope: String, CaseIterable, Identifiable {
    case this, following, all
    public var id: String { rawValue }
    /// Mirrors Apple Calendar wording (Jakob's law).
    public var label: String {
        switch self {
        case .this: return "This class only"
        case .following: return "This and all following classes"
        case .all: return "All classes"
        }
    }
}

public struct ScheduleChange: Equatable {
    public var newDate: LocalDate?
    public var newStart: LocalTime?
    public var newEnd: LocalTime?
    public var newLocation: String?
    public var cancel: Bool
    public init(newDate: LocalDate? = nil, newStart: LocalTime? = nil, newEnd: LocalTime? = nil, newLocation: String? = nil, cancel: Bool = false) {
        self.newDate = newDate; self.newStart = newStart; self.newEnd = newEnd; self.newLocation = newLocation; self.cancel = cancel
    }
}

public enum Mutation: Equatable {
    case upsertException(ClassException)
    case deleteException(id: Int)
    case updatePattern(ClassPattern)
    /// Inserts a pattern, then moves the listed exceptions onto it.
    case insertPattern(ClassPattern, reparentExceptionIds: [Int])
    case deletePattern(id: Int)
    case updateEvent(Event)
}

public struct EditPlan {
    public var mutations: [Mutation]
    public var warnings: [String]
    public init(mutations: [Mutation], warnings: [String]) { self.mutations = mutations; self.warnings = warnings }
}

public enum EditPlanner {
    /// Turns a user edit on one occurrence into mutations for a single transaction (§5.2).
    public static func plan(
        occurrence: Occurrence, scope: EditScope, change: ScheduleChange,
        patterns: [ClassPattern], exceptions: [ClassException], events: [Event]
    ) -> EditPlan {
        switch occurrence.origin {
        case .event(let eventId):
            guard var e = events.first(where: { $0.id == eventId }) else { return EditPlan(mutations: [], warnings: ["That event no longer exists."]) }
            let tz = TimeZone.current
            if change.cancel { e.canceled = true } else {
                let duration = (e.end ?? e.start.adding(minutes: 60)).timeIntervalSince(e.start)
                let oldDate = LocalDate(e.start, tz: tz)
                let date = change.newDate ?? oldDate
                let st = change.newStart ?? LocalTime(e.start, tz: tz)
                e.start = date.at(st, tz: tz)
                if let ne = change.newEnd { e.end = date.at(ne, tz: tz) } else { e.end = e.start.addingTimeInterval(duration) }
                if let loc = change.newLocation { e.location = loc.isEmpty ? nil : loc }
                e.canceled = false
            }
            e.userModified = true
            return EditPlan(mutations: [.updateEvent(e)], warnings: [])

        case .pattern(let patternId, let originalDate):
            guard let p = patterns.first(where: { $0.id == patternId }) else {
                return EditPlan(mutations: [], warnings: ["That class pattern no longer exists."])
            }
            let exs = exceptions.filter { $0.patternId == patternId }
            switch scope {
            case .this: return planThis(p, originalDate, change, exs)
            case .following:
                if originalDate <= p.validFrom { return planAll(p, originalDate, change, exs) }
                return planFollowing(p, originalDate, change, exs)
            case .all: return planAll(p, originalDate, change, exs)
            }
        }
    }

    static func planThis(_ p: ClassPattern, _ od: LocalDate, _ change: ScheduleChange, _ exs: [ClassException]) -> EditPlan {
        let existing = exs.first { $0.originalDate == od }
        var ex = existing ?? ClassException(patternId: p.id, originalDate: od, kind: .modify)
        if change.cancel {
            ex.kind = .cancel
            ex.newDate = nil; ex.newStartTime = nil; ex.newEndTime = nil; ex.newLocation = nil
            return EditPlan(mutations: [.upsertException(ex)], warnings: [])
        }
        ex.kind = .modify
        if let d = change.newDate { ex.newDate = d == od ? nil : d }
        if let s = change.newStart { ex.newStartTime = s == p.startTime ? nil : s }
        if let e = change.newEnd { ex.newEndTime = e == p.endTime ? nil : e }
        if let l = change.newLocation { ex.newLocation = (l == (p.location ?? "") || l.isEmpty) ? nil : l }
        let isNoop = ex.newDate == nil && ex.newStartTime == nil && ex.newEndTime == nil && ex.newLocation == nil && ex.note == nil
        if isNoop {
            // Moving a class back to its normal slot removes the exception.
            if let existing { return EditPlan(mutations: [.deleteException(id: existing.id)], warnings: []) }
            return EditPlan(mutations: [], warnings: [])
        }
        return EditPlan(mutations: [.upsertException(ex)], warnings: [])
    }

    /// Applies a change to a pattern template. A date move shifts the weekday by the same number of days.
    static func applied(_ p: ClassPattern, _ od: LocalDate, _ change: ScheduleChange) -> ClassPattern {
        var n = p
        if let d = change.newDate {
            let delta = od.days(to: d)
            n.weekday = ((p.weekday - 1 + delta) % 7 + 7) % 7 + 1
        }
        if let s = change.newStart {
            let duration = p.endTime.minutes - p.startTime.minutes
            n.startTime = s
            n.endTime = change.newEnd ?? LocalTime(minutes: min(s.minutes + duration, 23 * 60 + 59))
        } else if let e = change.newEnd {
            n.endTime = e
        }
        if let l = change.newLocation { n.location = l.isEmpty ? nil : l }
        n.userModified = true
        return n
    }

    static func planFollowing(_ p: ClassPattern, _ od: LocalDate, _ change: ScheduleChange, _ exs: [ClassException]) -> EditPlan {
        var old = p
        old.validTo = od.adding(days: -1)
        old.userModified = true
        if change.cancel {
            let dropped = exs.filter { $0.originalDate >= od }
            return EditPlan(mutations: [.updatePattern(old)] + dropped.map { .deleteException(id: $0.id) }, warnings: [])
        }
        var new = applied(p, od, change)
        new.id = 0
        new.externalUid = nil
        let delta = change.newDate.map { od.days(to: $0) } ?? 0
        new.validFrom = od.adding(days: delta)
        new.validTo = p.validTo
        let after = exs.filter { $0.originalDate >= od }
        var warnings: [String] = []
        var mutations: [Mutation] = [.updatePattern(old)]
        if new.weekday == p.weekday {
            mutations.append(.insertPattern(new, reparentExceptionIds: after.map(\.id)))
        } else {
            mutations.append(.insertPattern(new, reparentExceptionIds: []))
            if !after.isEmpty {
                mutations += after.map { .deleteException(id: $0.id) }
                warnings.append("Removed \(after.count) one-off change\(after.count == 1 ? "" : "s") that no longer line up with the new day: "
                    + after.map(\.originalDate.string).joined(separator: ", ") + ".")
            }
        }
        return EditPlan(mutations: mutations, warnings: warnings)
    }

    static func planAll(_ p: ClassPattern, _ od: LocalDate, _ change: ScheduleChange, _ exs: [ClassException]) -> EditPlan {
        if change.cancel {
            return EditPlan(mutations: [.deletePattern(id: p.id)], warnings: ["Removed every class in this series."])
        }
        let n = applied(p, od, change)
        var mutations: [Mutation] = [.updatePattern(n)]
        var warnings: [String] = []
        if n.weekday != p.weekday && !exs.isEmpty {
            mutations += exs.map { .deleteException(id: $0.id) }
            warnings.append("Removed \(exs.count) one-off change\(exs.count == 1 ? "" : "s") that no longer line up with the new day: "
                + exs.map(\.originalDate.string).joined(separator: ", ") + ".")
        }
        return EditPlan(mutations: mutations, warnings: warnings)
    }

    /// "This changes 11 classes" preview for following/all.
    public static func affectedCount(occurrence: Occurrence, scope: EditScope, patterns: [ClassPattern], breaks: [TermBreak]) -> Int {
        guard case .pattern(let pid, let od) = occurrence.origin, let p = patterns.first(where: { $0.id == pid }) else { return 1 }
        switch scope {
        case .this: return 1
        case .following: return countDates(p, from: od, breaks: breaks)
        case .all: return countDates(p, from: p.validFrom, breaks: breaks)
        }
    }

    static func countDates(_ p: ClassPattern, from: LocalDate, breaks: [TermBreak]) -> Int {
        var d = max(from, p.validFrom)
        d = d.adding(days: (p.weekday - d.weekday + 7) % 7)
        var n = 0
        while d <= p.validTo {
            if !breaks.contains(where: { $0.contains(d) }) { n += 1 }
            d = d.adding(days: 7)
        }
        return n
    }
}
