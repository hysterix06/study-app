import Foundation

/// Maps parsed iCalendar events onto Study Tracker rows (§6.2). Pure: it produces a plan that the
/// repository applies in one transaction after the student sees the preview.
public struct ICSImportPlan {
    public enum Action: String { case create, update, unchanged, conflict }
    public enum CourseRef: Hashable { case existing(Int), new(key: String) }

    public struct NewCourse: Hashable { public var key: String; public var name: String; public var code: String? }
    public struct PatternOp { public var uid: String; public var course: CourseRef; public var pattern: ClassPattern; public var existingId: Int?; public var action: Action }
    public struct ExceptionOp { public var patternUid: String; public var exception: ClassException }
    public struct EventOp { public var course: CourseRef?; public var event: Event; public var existingId: Int?; public var action: Action }
    public struct AssignmentOp { public var course: CourseRef?; public var assignment: Assignment; public var existingId: Int?; public var action: Action }
    public struct ConflictOp { public var entity: String; public var entityId: Int; public var summary: String; public var incoming: [String: Any] }

    public var newCourses: [NewCourse] = []
    public var patterns: [PatternOp] = []
    public var exceptions: [ExceptionOp] = []
    public var events: [EventOp] = []
    public var assignments: [AssignmentOp] = []
    public var conflicts: [ConflictOp] = []
    public var staleEventIds: [Int] = []
    public var role: String = "school"

    public var newCount: Int {
        patterns.filter { $0.action == .create }.count + events.filter { $0.action == .create }.count
            + assignments.filter { $0.action == .create }.count
    }
    public var changedCount: Int {
        patterns.filter { $0.action == .update }.count + events.filter { $0.action == .update }.count
            + assignments.filter { $0.action == .update }.count
    }
    public var conflictCount: Int { conflicts.count }
    public var summary: String {
        var parts = ["\(newCount) new", "\(changedCount) changed", "\(conflictCount) conflict\(conflictCount == 1 ? "" : "s")"]
        if !newCourses.isEmpty { parts.append("\(newCourses.count) new course\(newCourses.count == 1 ? "" : "s")") }
        if !staleEventIds.isEmpty { parts.append("\(staleEventIds.count) removed") }
        return parts.joined(separator: ", ")
    }
    public var isEmpty: Bool { newCount == 0 && changedCount == 0 && conflictCount == 0 && staleEventIds.isEmpty && exceptions.isEmpty }
}

public enum ICSMapper {
    public struct Existing {
        public var patterns: [String: ClassPattern] = [:]      // by external_uid
        public var events: [String: Event] = [:]               // by external_uid (source ics)
        public var assignments: [String: Assignment] = [:]     // by external_uid (source ics)
        public var sourceEventUids: [String: Int] = [:]        // uid → id for this calendar source
        public init() {}
    }

    public static func plan(
        events input: [ICSEvent], courses: [Course], term: Term?, defaultTZ: TimeZone, role: String,
        existing: Existing, now: Date
    ) -> ICSImportPlan {
        var plan = ICSImportPlan()
        plan.role = role
        let horizonEnd = term?.endDate ?? LocalDate(now, tz: defaultTZ).adding(days: 120)
        var seenEventUids = Set<String>()

        var newCourseKeys: [String: ICSImportPlan.NewCourse] = [:]
        func courseRef(for summary: String, create: Bool) -> ICSImportPlan.CourseRef? {
            if let c = CourseMatcher.best(summary, courses: courses) { return .existing(c.id) }
            guard create else { return nil }
            let code = CourseMatcher.extractCode(summary)
            let key = (code ?? cleanedTitle(summary)).lowercased()
            if newCourseKeys[key] == nil {
                var name = cleanedTitle(summary)
                if let code { name = name.replacingOccurrences(of: code, with: "").trimmingCharacters(in: CharacterSet(charactersIn: " -–:|")) }
                if name.isEmpty { name = code ?? summary }
                newCourseKeys[key] = .init(key: key, name: name, code: code)
            }
            return .new(key: key)
        }

        let masters = input.filter { $0.recurrenceId == nil }
        let overrides = Dictionary(grouping: input.filter { $0.recurrenceId != nil }, by: { $0.uid })

        for ev in masters {
            guard let dtstart = ev.dtstart else { continue }
            if ev.isCancelled { continue }
            let isWeekly = ev.rrule?.freq == "WEEKLY" && (ev.rrule?.interval ?? 1) == 1 && !dtstart.isDateOnly

            if role == "school", isWeekly, let rule = ev.rrule {
                let tz: TimeZone = dtstart.isUTC ? defaultTZ : dtstart.timeZone(default: defaultTZ)
                let (startDate, startTime) = dtstart.local(in: tz, default: defaultTZ)
                let endInstant = ev.endInstant(default: defaultTZ) ?? dtstart.instant(default: defaultTZ).adding(minutes: 60)
                let endTime = LocalTime(endInstant, tz: tz)
                let days = rule.byDay.isEmpty ? [startDate.weekday] : rule.byDay
                var validTo = horizonEnd
                if let until = rule.until {
                    validTo = until.isDateOnly ? until.date : LocalDate(until.instant(default: tz), tz: tz)
                } else if let count = rule.count {
                    var n = 0
                    var d = startDate
                    while n < count && d.year < startDate.year + 5 {
                        if days.contains(d.weekday) { n += 1; validTo = d }
                        d = d.adding(days: 1)
                    }
                }
                guard let course = courseRef(for: ev.summary, create: true) else { continue }
                for wd in days.sorted() {
                    let uid = days.count > 1 ? "\(ev.uid)#\(wd)" : ev.uid
                    let p = ClassPattern(courseId: 0, weekday: wd, startTime: startTime, endTime: endTime,
                                         location: ev.location, validFrom: startDate, validTo: validTo,
                                         timezone: tz.identifier, externalUid: uid)
                    var action = ICSImportPlan.Action.create
                    var existingId: Int?
                    if let old = existing.patterns[uid] {
                        existingId = old.id
                        let same = old.weekday == p.weekday && old.startTime == p.startTime && old.endTime == p.endTime
                            && (old.location ?? "") == (p.location ?? "") && old.validFrom == p.validFrom && old.validTo == p.validTo
                        if same { action = .unchanged }
                        else if old.userModified {
                            action = .conflict
                            plan.conflicts.append(.init(entity: "class_pattern", entityId: old.id,
                                summary: "\(ev.summary): the school calendar changed a class you edited.",
                                incoming: ["weekday": wd, "start_time": startTime.string, "end_time": endTime.string,
                                           "location": ev.location ?? "", "valid_from": startDate.string, "valid_to": validTo.string]))
                        } else { action = .update }
                    }
                    plan.patterns.append(.init(uid: uid, course: course, pattern: p, existingId: existingId, action: action))
                }
                func patternUid(for date: LocalDate) -> String? {
                    guard days.contains(date.weekday) else { return nil }
                    return days.count > 1 ? "\(ev.uid)#\(date.weekday)" : ev.uid
                }
                for ex in ev.exdates {
                    let (d, _) = ex.local(in: tz, default: tz)
                    guard let puid = patternUid(for: d) else { continue }
                    plan.exceptions.append(.init(patternUid: puid, exception: ClassException(patternId: 0, originalDate: d, kind: .cancel)))
                }
                for o in overrides[ev.uid] ?? [] {
                    guard let rid = o.recurrenceId, let os = o.dtstart else { continue }
                    let (od, _) = rid.local(in: tz, default: tz)
                    guard let puid = patternUid(for: od) else { continue }
                    if o.isCancelled {
                        plan.exceptions.append(.init(patternUid: puid, exception: ClassException(patternId: 0, originalDate: od, kind: .cancel)))
                        continue
                    }
                    let (nd, nt) = os.local(in: tz, default: tz)
                    let oe = o.endInstant(default: tz).map { LocalTime($0, tz: tz) }
                    var ex = ClassException(patternId: 0, originalDate: od, kind: .modify)
                    ex.newDate = nd == od ? nil : nd
                    ex.newStartTime = nt == startTime ? nil : nt
                    ex.newEndTime = oe == endTime ? nil : oe
                    if let loc = o.location, loc != ev.location { ex.newLocation = loc }
                    if ex.newDate != nil || ex.newStartTime != nil || ex.newEndTime != nil || ex.newLocation != nil {
                        plan.exceptions.append(.init(patternUid: puid, exception: ex))
                    }
                }
                continue
            }

            // Everything else becomes individual rows: single events, other recurrence rules, busy calendars.
            let instances = expandInstances(ev, overrides: overrides[ev.uid] ?? [], defaultTZ: defaultTZ,
                                            horizonStart: role == "busy" ? LocalDate(now, tz: defaultTZ).adding(days: -7) : nil,
                                            horizonEnd: role == "busy" ? LocalDate(now, tz: defaultTZ).adding(days: 120) : horizonEnd)
            for inst in instances {
                seenEventUids.insert(inst.uid)
                if role == "school", CourseMatcher.looksLikeDeadline(inst.summary) {
                    let course = courseRef(for: ([inst.summary] + inst.categories).joined(separator: " "), create: false)
                    var a = Assignment(courseId: nil, title: cleanedTitle(inst.summary), description: inst.description,
                                       kind: CourseMatcher.guessKind(inst.summary), dueAt: inst.start, confirmed: false,
                                       source: "ics", externalUid: inst.uid, url: inst.url)
                    if inst.allDay { a.dueAt = nil; a.description = [a.description, "All-day on \(LocalDate(inst.start, tz: TimeZone(identifier: "UTC")!).string)"].compactMap { $0 }.joined(separator: "\n") }
                    var action = ICSImportPlan.Action.create
                    var existingId: Int?
                    if let old = existing.assignments[inst.uid] {
                        existingId = old.id
                        if old.dismissed || (old.dueAt == a.dueAt && old.title == a.title) { action = .unchanged }
                        else if old.userModified || old.confirmed {
                            action = .conflict
                            plan.conflicts.append(.init(entity: "assignment", entityId: old.id,
                                summary: "\(old.title): the calendar now says \(a.dueAt.map { ISO.instant($0, in: defaultTZ) } ?? "no date").",
                                incoming: ["title": a.title, "due_at": a.dueAt.map { ISO.instant($0) } as Any]))
                        } else { action = .update }
                    }
                    plan.assignments.append(.init(course: course, assignment: a, existingId: existingId, action: action))
                    continue
                }
                let course = role == "busy" ? nil : courseRef(for: ([inst.summary] + inst.categories).joined(separator: " "), create: false)
                var e = Event(courseId: nil, title: inst.summary.isEmpty ? "Busy" : inst.summary,
                              kind: role == "busy" ? "busy" : (course != nil ? "class" : "event"),
                              start: inst.start, end: inst.end, allDay: inst.allDay, location: inst.location,
                              notes: inst.description, source: "ics", externalUid: inst.uid)
                if role == "busy" { e.notes = nil }
                var action = ICSImportPlan.Action.create
                var existingId: Int?
                if let old = existing.events[inst.uid] {
                    existingId = old.id
                    let same = old.start == e.start && old.end == e.end && old.title == e.title && (old.location ?? "") == (e.location ?? "")
                    if same { action = .unchanged }
                    else if old.userModified {
                        action = .conflict
                        plan.conflicts.append(.init(entity: "event", entityId: old.id,
                            summary: "\(old.title): the calendar changed an event you edited.",
                            incoming: ["title": e.title, "start_at": ISO.instant(e.start), "end_at": e.end.map { ISO.instant($0) } as Any,
                                       "location": e.location as Any]))
                    } else { action = .update }
                }
                plan.events.append(.init(course: course, event: e, existingId: existingId, action: action))
            }
        }

        // Future events from this source that disappeared from the calendar.
        for (uid, id) in existing.sourceEventUids where !seenEventUids.contains(uid) {
            if let old = existing.events[uid], old.start > now, !old.userModified { plan.staleEventIds.append(id) }
        }

        plan.newCourses = Array(newCourseKeys.values).sorted { $0.name < $1.name }
        return plan
    }

    struct Instance { var uid: String; var summary: String; var start: Date; var end: Date?; var allDay: Bool; var location: String?; var description: String?; var url: String?; var categories: [String] = [] }

    static func expandInstances(_ ev: ICSEvent, overrides: [ICSEvent], defaultTZ: TimeZone, horizonStart: LocalDate?, horizonEnd: LocalDate) -> [Instance] {
        guard let dtstart = ev.dtstart else { return [] }
        let tz = dtstart.isUTC ? defaultTZ : dtstart.timeZone(default: defaultTZ)
        let allDay = dtstart.isDateOnly
        let duration = (ev.endInstant(default: defaultTZ) ?? dtstart.instant(default: defaultTZ).adding(minutes: 60))
            .timeIntervalSince(dtstart.instant(default: defaultTZ))
        func startInstant(_ d: LocalDate) -> Date {
            if allDay { return d.utcMidnight }
            let (_, t) = dtstart.local(in: tz, default: defaultTZ)
            return d.at(t, tz: tz)
        }
        guard let rule = ev.rrule else {
            let s = allDay ? dtstart.date.utcMidnight : dtstart.instant(default: defaultTZ)
            return [Instance(uid: ev.uid, summary: ev.summary, start: s, end: allDay ? nil : s.addingTimeInterval(duration),
                             allDay: allDay, location: ev.location, description: ev.description, url: ev.url, categories: ev.categories)]
        }
        let (firstDate, _) = dtstart.local(in: tz, default: defaultTZ)
        var until = horizonEnd
        if let u = rule.until { until = min(until, u.isDateOnly ? u.date : LocalDate(u.instant(default: tz), tz: tz)) }
        let exdates = Set(ev.exdates.map { $0.local(in: tz, default: tz).0 })
        let overrideByDate = Dictionary(overrides.compactMap { o -> (LocalDate, ICSEvent)? in
            guard let r = o.recurrenceId else { return nil }
            return (r.local(in: tz, default: tz).0, o)
        }, uniquingKeysWith: { a, _ in a })

        var dates: [LocalDate] = []
        var d = firstDate
        var guardCount = 0
        let byDay = rule.byDay.isEmpty ? [firstDate.weekday] : rule.byDay
        while d <= until && dates.count < 400 && guardCount < 5000 {
            guardCount += 1
            switch rule.freq {
            case "DAILY":
                dates.append(d); d = d.adding(days: rule.interval)
            case "WEEKLY":
                let weekStart = d.startOfWeek()
                for wd in byDay.sorted() {
                    let x = weekStart.adding(days: wd - 1)
                    if x >= firstDate && x <= until { dates.append(x) }
                }
                d = weekStart.adding(days: 7 * rule.interval)
            case "MONTHLY":
                dates.append(d); d = d.adding(months: rule.interval)
            case "YEARLY":
                dates.append(d); d = LocalDate(year: d.year + rule.interval, month: d.month, day: d.day)
            default:
                dates.append(d); d = until.adding(days: 1)
            }
            if let c = rule.count, dates.count >= c { dates = Array(dates.prefix(c)); break }
        }
        var out: [Instance] = []
        for date in dates where !exdates.contains(date) {
            if let hs = horizonStart, date < hs { continue }
            let uid = "\(ev.uid)@\(date.string)"
            if let o = overrideByDate[date] {
                if o.isCancelled { continue }
                guard let os = o.dtstart else { continue }
                let s = os.isDateOnly ? os.date.utcMidnight : os.instant(default: tz)
                out.append(Instance(uid: uid, summary: o.summary.isEmpty ? ev.summary : o.summary, start: s,
                                    end: os.isDateOnly ? nil : (o.endInstant(default: tz) ?? s.addingTimeInterval(duration)),
                                    allDay: os.isDateOnly, location: o.location ?? ev.location, description: o.description ?? ev.description, url: ev.url,
                                    categories: ev.categories))
            } else {
                let s = startInstant(date)
                out.append(Instance(uid: uid, summary: ev.summary, start: s, end: allDay ? nil : s.addingTimeInterval(duration),
                                    allDay: allDay, location: ev.location, description: ev.description, url: ev.url, categories: ev.categories))
            }
        }
        return out
    }

    static func cleanedTitle(_ s: String) -> String {
        var t = s
        for suffix in [" is due", " due", " opens", " closes", " (due)"] where t.lowercased().hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
