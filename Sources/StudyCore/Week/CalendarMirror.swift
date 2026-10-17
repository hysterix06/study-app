import Foundation

/// Deadlines copied into an Apple Calendar calendar of the app's own, so they reach the student's phone. The app owns
/// that calendar: each sync makes it hold exactly the work still to hand in, and anything else in it goes.
public enum CalendarMirror {
    public static let calendarTitle = "Study Tracker deadlines"

    public struct Entry: Hashable, Sendable {
        public var deadlineId: Int
        public var title: String
        public var due: Date
        public var url: String?
        public var fingerprint: String { [title, ISO.instant(due), url ?? ""].joined(separator: "|") }
    }

    /// What the calendar should hold: "Pricing report · Marketing" at the due time.
    public static func entries(deadlines: [Deadline], courses: [Course]) -> [Entry] {
        let titles = Dictionary(courses.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        return deadlines.compactMap { d in
            guard let due = d.dueAt, !d.submitted else { return nil }
            return Entry(deadlineId: d.id, title: [d.title, titles[d.courseId]].compactMap { $0 }.joined(separator: " · "), due: due, url: d.url)
        }
    }

    public struct Plan: Equatable, Sendable {
        public var create: [Entry] = []
        public var update: [Update] = []
        /// Calendar events to remove.
        public var delete: [String] = []
        public var isEmpty: Bool { create.isEmpty && update.isEmpty && delete.isEmpty }
    }

    public struct Update: Equatable, Sendable {
        public var eventId: String
        public var entry: Entry
    }

    /// `stored` is what each deadline was last copied as (its event and fingerprint); `inCalendar` the events the
    /// calendar holds now. A copied event the student deleted is made again.
    public static func plan(entries: [Entry], stored: [Int: (eventId: String, fingerprint: String?)], inCalendar: Set<String>) -> Plan {
        var plan = Plan()
        var keep = Set<String>()
        for e in entries {
            if let s = stored[e.deadlineId], inCalendar.contains(s.eventId) {
                keep.insert(s.eventId)
                if s.fingerprint != e.fingerprint { plan.update.append(Update(eventId: s.eventId, entry: e)) }
            } else {
                plan.create.append(e)
            }
        }
        plan.delete = inCalendar.subtracting(keep).sorted()
        return plan
    }
}

extension BookStore {
    /// Work to copy to the calendar: not handed in, due from two weeks ago on, in visible courses.
    public func deadlinesToMirror(now: Date = Date()) -> [Deadline] {
        let rows = (try? db.query("""
            SELECT d.* FROM deadlines d JOIN courses c ON c.id = d.course_id
            WHERE c.hidden = 0 AND d.submitted = 0 AND d.due_at IS NOT NULL AND d.due_at >= ? ORDER BY d.due_at
            """, [now.addingTimeInterval(-14 * 86_400)])) ?? []
        return rows.map(Deadline.init(row:))
    }

    public func mirrorState() -> [Int: (eventId: String, fingerprint: String?)] {
        let rows = (try? db.query("SELECT id, ek_event_id, ek_fingerprint FROM deadlines WHERE ek_event_id IS NOT NULL")) ?? []
        return Dictionary(rows.map { ($0.i("id"), (eventId: $0.str("ek_event_id"), fingerprint: $0.string("ek_fingerprint"))) }, uniquingKeysWith: { a, _ in a })
    }

    public func setMirrored(_ deadlineId: Int, eventId: String?, fingerprint: String?) {
        _ = try? db.execute("UPDATE deadlines SET ek_event_id = ?, ek_fingerprint = ? WHERE id = ?", [eventId, fingerprint, deadlineId])
    }

    public func clearMirrorState() {
        _ = try? db.execute("UPDATE deadlines SET ek_event_id = NULL, ek_fingerprint = NULL")
    }
}
