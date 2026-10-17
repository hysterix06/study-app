import Foundation

/// What Home's "This week" shows: classes from the timetable and Moodle deadlines, day by day from today, plus work
/// already overdue.
public enum Agenda {
    public struct Item: Identifiable, Hashable, Sendable {
        public enum Kind: Sendable { case lesson, deadline }
        public var id: String
        public var kind: Kind
        public var title: String
        public var start: Date
        public var end: Date?
        public var allDay: Bool
        public var location: String?
        public var courseId: Int?
        public var cancelled = false
        public var url: String?
    }

    public struct Day: Identifiable, Hashable, Sendable {
        public var date: LocalDate
        public var items: [Item]
        public var id: String { date.string }
    }

    public static func week(classes: [Timetable.Instance], deadlines: [Deadline], courses: [Course], now: Date = Date(), days: Int = 7,
                            tz: TimeZone = .current) -> (overdue: [Item], days: [Day]) {
        let names = courses.map { CourseName(id: $0.id, name: $0.name, code: $0.code, aliases: [$0.bookTitle].compactMap { $0 }) }
        var matched: [String: Int?] = [:]
        func course(_ title: String) -> Int? {
            if let hit = matched[title] { return hit }
            let id = CourseMatcher.best(title, courses: names)?.id
            matched[title] = id
            return id
        }
        let today = LocalDate(now, tz: tz)
        // A calendar that also carries Moodle's deadlines ("Pricing report is due") would show each one twice.
        let due = deadlines.compactMap { d in d.dueAt.map { (title: d.title.lowercased(), at: $0) } }
        var byDay: [LocalDate: [Item]] = [:]
        for c in classes {
            let t = Timetable.cleanedTitle(c.summary).lowercased()
            if !c.allDay, !t.isEmpty, due.contains(where: { abs($0.at.timeIntervalSince(c.start)) < 60 && ($0.title.hasPrefix(t) || t.hasPrefix($0.title)) }) { continue }
            let item = Item(id: "class:\(c.uid)", kind: .lesson, title: c.summary, start: c.start, end: c.end, allDay: c.allDay,
                            location: c.location, courseId: course(c.summary), cancelled: c.cancelled)
            // An all-day event is stored at UTC midnight; anything else falls on its local day.
            let day = c.allDay ? LocalDate(c.start, tz: TimeZone(identifier: "UTC")!) : LocalDate(c.start, tz: tz)
            byDay[day, default: []].append(item)
        }
        var overdue: [Item] = []
        for d in deadlines {
            guard let due = d.dueAt, !d.submitted else { continue }
            let item = Item(id: "deadline:\(d.id)", kind: .deadline, title: d.title, start: due, end: nil, allDay: false,
                            location: nil, courseId: d.courseId, url: d.url)
            if due < now { overdue.append(item) } else { byDay[LocalDate(due, tz: tz), default: []].append(item) }
        }
        let out = (0..<days).compactMap { i -> Day? in
            let date = today.adding(days: i)
            guard let items = byDay[date], !items.isEmpty else { return nil }
            return Day(date: date, items: items.sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) })
        }
        return (overdue.sorted { $0.start < $1.start }, out)
    }
}
