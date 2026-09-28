import Foundation

public struct PlannerSettings: Equatable {
    public var windowStart = LocalTime(hour: 8, minute: 0)
    public var windowEnd = LocalTime(hour: 22, minute: 0)
    public var maxMinutesPerDay = 180
    public var defaultHoursExam = 6.0
    public var defaultHoursOther = 3.0
    public var horizonDays = 21
    public init() {}
}

public struct PlannerResult {
    public var blocks: [StudyBlock]
    public var warnings: [String]
}

/// Deterministic study-block planner (§9.5): works backward from each deadline, avoids classes, busy time
/// (work shifts) and existing blocks, and caps daily study.
public enum StudyPlanner {
    public static func plan(assignments: [Assignment], busy: [(start: Date, end: Date)], existing: [StudyBlock],
                            settings: PlannerSettings, now: Date, tz: TimeZone) -> PlannerResult {
        let horizon = now.adding(days: Double(settings.horizonDays))
        let open = assignments.filter { a in
            guard a.confirmed, a.isOpen, let due = a.dueAt else { return false }
            return due > now && due <= horizon && a.courseId != nil
        }
        // Earliest deadline first; heavier weight breaks ties so big items get the good slots.
        .sorted { ($0.dueAt!, -($0.weightPct ?? 0)) < ($1.dueAt!, -($1.weightPct ?? 0)) }

        var taken: [(Date, Date)] = busy.map { ($0.start, $0.end) }
        var minutesByDay: [LocalDate: Int] = [:]
        for b in existing where b.status != "dismissed" && b.status != "skipped" {
            taken.append((b.plannedStart, b.end))
            minutesByDay[LocalDate(b.plannedStart, tz: tz), default: 0] += b.plannedMinutes
        }
        var out: [StudyBlock] = []
        var warnings: [String] = []

        for a in open {
            let due = a.dueAt!
            let already = existing.filter { $0.assignmentId == a.id && ($0.status == "planned" || $0.status == "done" || $0.status == "proposed") }
                .reduce(0) { $0 + $1.plannedMinutes }
            let defaultHours = a.kind == .exam ? settings.defaultHoursExam : (a.estHours == nil ? settings.defaultHoursOther : a.hoursNeeded)
            let progressFactor = a.status == .inProgress ? 0.5 : 1.0
            var needed = Int(((a.estHours ?? defaultHours) * 60 * progressFactor).rounded()) - already
            guard needed >= 20 else { continue }
            let sizes = split(minutes: needed)
            let latestEnd = due.adding(hours: -12)
            var day = LocalDate(latestEnd, tz: tz)
            let today = LocalDate(now, tz: tz)
            var placed = 0
            var usedDays = Set<LocalDate>()
            var sizeIndex = 0
            while sizeIndex < sizes.count && day >= today {
                let size = sizes[sizeIndex]
                let finalStretch = due.timeIntervalSince(day.at(LocalTime(hour: 12, minute: 0), tz: tz)) <= 48 * 3600
                if usedDays.contains(day) && !finalStretch { day = day.adding(days: -1); continue }
                let dayUsed = minutesByDay[day, default: 0]
                if dayUsed + size > settings.maxMinutesPerDay { day = day.adding(days: -1); continue }
                if let slot = latestSlot(on: day, minutes: size, before: latestEnd, after: now, taken: taken, settings: settings, tz: tz) {
                    let block = StudyBlock(courseId: a.courseId, assignmentId: a.id, plannedStart: slot, plannedMinutes: size,
                                           focus: a.title, status: "proposed", createdBy: "planner")
                    out.append(block)
                    taken.append((slot, slot.adding(minutes: size)))
                    minutesByDay[day, default: 0] += size
                    usedDays.insert(day)
                    placed += size
                    sizeIndex += 1
                    needed -= size
                    // Allow a second block the same day only in the final 48 hours.
                    if !finalStretch { day = day.adding(days: -1) }
                } else {
                    day = day.adding(days: -1)
                }
            }
            if sizeIndex < sizes.count {
                let f = DateFormatter()
                f.dateFormat = "EEEE"
                f.timeZone = tz
                let missing = sizes[sizeIndex...].reduce(0, +)
                warnings.append("Not enough free time before \(f.string(from: due)) for \(a.title) (\(String(format: "%.1f", Double(missing) / 60)) h short).")
            }
        }
        return PlannerResult(blocks: out.sorted { $0.plannedStart < $1.plannedStart }, warnings: warnings)
    }

    /// Blocks of 45–90 minutes: 60-minute blocks with the remainder folded in.
    static func split(minutes: Int) -> [Int] {
        if minutes <= 90 { return [max(45, minutes)] }
        var sizes: [Int] = []
        var left = minutes
        while left > 0 {
            if left <= 90 { sizes.append(max(45, left)); break }
            if left < 105 { sizes.append(left - 45); sizes.append(45); break }
            sizes.append(60); left -= 60
        }
        return sizes
    }

    /// Latest free slot on a day that ends before `before`, snapped to quarter hours.
    static func latestSlot(on day: LocalDate, minutes: Int, before: Date, after: Date, taken: [(Date, Date)],
                           settings: PlannerSettings, tz: TimeZone) -> Date? {
        let windowStart = day.at(settings.windowStart, tz: tz)
        var end = min(day.at(settings.windowEnd, tz: tz), before)
        // Snap down to a quarter hour.
        let cal = calendar(in: tz)
        let m = cal.component(.minute, from: end)
        end = end.adding(minutes: -(m % 15))
        let earliest = max(windowStart, after.adding(minutes: 30))
        while end.adding(minutes: -minutes) >= earliest {
            let start = end.adding(minutes: -minutes)
            let clash = taken.first { $0.0 < end && $0.1 > start }
            if let clash {
                // Jump to just before the clashing item (with a 15-minute buffer), snapped.
                var next = clash.0.adding(minutes: -15)
                let mm = cal.component(.minute, from: next)
                next = next.adding(minutes: -(mm % 15)).addingTimeInterval(-Double(cal.component(.second, from: next)))
                if next >= end { next = end.adding(minutes: -15) }
                end = next
                continue
            }
            return start
        }
        return nil
    }

    /// Free study hours between now and a deadline (used by the Today ranking).
    public static func freeHours(until due: Date, busy: [(start: Date, end: Date)], settings: PlannerSettings, now: Date, tz: TimeZone) -> Double {
        guard due > now else { return 0 }
        var total = 0.0
        var day = LocalDate(now, tz: tz)
        let last = LocalDate(due, tz: tz)
        while day <= last {
            let ws = max(day.at(settings.windowStart, tz: tz), now)
            let we = min(day.at(settings.windowEnd, tz: tz), due)
            if we > ws {
                var free = we.timeIntervalSince(ws)
                for b in busy where b.start < we && b.end > ws {
                    free -= min(b.end, we).timeIntervalSince(max(b.start, ws))
                }
                total += min(max(free, 0) / 3600, Double(settings.maxMinutesPerDay) / 60)
            }
            day = day.adding(days: 1)
        }
        return total
    }
}
