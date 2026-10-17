import Foundation

/// The student's timetable from a calendar link or file: every event in a date range, with repeats expanded,
/// excluded dates dropped and moved or cancelled classes applied. Nothing is stored or edited, so each refresh of the
/// link simply replaces the old text.
public enum Timetable {
    public struct Instance: Hashable, Sendable {
        public var uid: String
        public var summary: String
        public var start: Date
        public var end: Date?
        public var allDay: Bool
        public var location: String?
        public var description: String?
        public var url: String?
        public var categories: [String] = []
        /// A class called off: still shown, struck through, so the gap in the week makes sense.
        public var cancelled = false

        public init(uid: String, summary: String, start: Date, end: Date?, allDay: Bool, location: String? = nil, description: String? = nil,
                    url: String? = nil, categories: [String] = [], cancelled: Bool = false) {
            self.uid = uid; self.summary = summary; self.start = start; self.end = end; self.allDay = allDay; self.location = location
            self.description = description; self.url = url; self.categories = categories; self.cancelled = cancelled
        }
    }

    /// Events overlapping `from` through `to` (whole days in `tz`), earliest first.
    public static func occurrences(_ events: [ICSEvent], from: LocalDate, to: LocalDate, tz: TimeZone) -> [Instance] {
        let masters = events.filter { $0.recurrenceId == nil }
        let overrides = Dictionary(grouping: events.filter { $0.recurrenceId != nil }, by: { $0.uid })
        var out = masters.flatMap { expand($0, overrides: overrides[$0.uid] ?? [], defaultTZ: tz, horizonStart: from, horizonEnd: to) }
        // A moved class whose series isn't in the file is still a class.
        let known = Set(masters.map(\.uid))
        for (uid, list) in overrides where !known.contains(uid) {
            for o in list {
                var single = o
                single.recurrenceId = nil
                out += expand(single, overrides: [], defaultTZ: tz, horizonStart: from, horizonEnd: to)
            }
        }
        let midnight = LocalTime(hour: 0, minute: 0)
        let lower = from.at(midnight, tz: tz), upper = to.adding(days: 1).at(midnight, tz: tz)
        return out.filter { $0.start < upper && ($0.end ?? $0.start.addingTimeInterval(1)) > lower }
            .map(markCancelled).sorted { $0.start < $1.start }
    }

    /// Outlook keeps a called-off class in attendees' calendars with "Canceled:" in front of its title.
    static let cancelledPrefix = try! NSRegularExpression(pattern: #"^\s*(cancell?ed|canceled|cancelad[oa]|annulé|abgesagt)\s*:\s*"#, options: .caseInsensitive)

    public static func markCancelled(_ i: Instance) -> Instance {
        var i = i
        let range = NSRange(i.summary.startIndex..., in: i.summary)
        if let m = cancelledPrefix.firstMatch(in: i.summary, range: range), let r = Range(m.range, in: i.summary) {
            i.summary.removeSubrange(r)
            i.cancelled = true
        }
        return i
    }

    static func expand(_ ev: ICSEvent, overrides: [ICSEvent], defaultTZ: TimeZone, horizonStart: LocalDate?, horizonEnd: LocalDate) -> [Instance] {
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
                             allDay: allDay, location: ev.location, description: ev.description, url: ev.url, categories: ev.categories,
                             cancelled: ev.isCancelled)]
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
        let step = max(1, rule.interval)
        // A series that began long ago (a daily or weekly class since last year) starts counting near the window,
        // or it would run out of its 400 dates before reaching today. A COUNT has to be counted from the start.
        if rule.count == nil, let hs = horizonStart, hs > firstDate {
            switch rule.freq {
            case "DAILY": d = firstDate.adding(days: firstDate.days(to: hs) / step * step)
            case "WEEKLY":
                let first = firstDate.startOfWeek()
                d = first.adding(days: 7 * (first.days(to: hs.startOfWeek()) / 7 / step * step))
            default: break
            }
        }
        while d <= until && dates.count < 400 && guardCount < 5000 {
            guardCount += 1
            switch rule.freq {
            case "DAILY":
                dates.append(d); d = d.adding(days: step)
            case "WEEKLY":
                let weekStart = d.startOfWeek()
                for wd in byDay.sorted() {
                    let x = weekStart.adding(days: wd - 1)
                    if x >= firstDate && x <= until { dates.append(x) }
                }
                d = weekStart.adding(days: 7 * step)
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
                guard let os = o.dtstart else { continue }
                let s = os.isDateOnly ? os.date.utcMidnight : os.instant(default: tz)
                out.append(Instance(uid: uid, summary: o.summary.isEmpty ? ev.summary : o.summary, start: s,
                                    end: os.isDateOnly ? nil : (o.endInstant(default: tz) ?? s.addingTimeInterval(duration)),
                                    allDay: os.isDateOnly, location: o.location ?? ev.location, description: o.description ?? ev.description, url: ev.url,
                                    categories: ev.categories, cancelled: o.isCancelled))
            } else {
                let s = startInstant(date)
                out.append(Instance(uid: uid, summary: ev.summary, start: s, end: allDay ? nil : s.addingTimeInterval(duration),
                                    allDay: allDay, location: ev.location, description: ev.description, url: ev.url, categories: ev.categories,
                                    cancelled: ev.isCancelled))
            }
        }
        return out
    }

    public static func cleanedTitle(_ s: String) -> String {
        var t = s
        for suffix in [" is due", " due", " opens", " closes", " (due)"] where t.lowercased().hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
