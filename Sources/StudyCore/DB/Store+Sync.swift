import Foundation

/// Bookkeeping for one-way sync to Apple Calendar and Reminders.
public extension StudyStore {
    struct SyncEntry { public var key: String; public var targetId: String; public var fingerprint: String }

    func syncEntries(target: String) -> [String: SyncEntry] {
        let rows = (try? db.query("SELECT entity_key, target_id, fingerprint FROM sync_map WHERE target = ?", [target])) ?? []
        var out: [String: SyncEntry] = [:]
        for r in rows { out[r.str("entity_key")] = SyncEntry(key: r.str("entity_key"), targetId: r.str("target_id"), fingerprint: r.str("fingerprint")) }
        return out
    }

    func setSyncEntry(target: String, key: String, targetId: String, fingerprint: String) {
        _ = try? db.execute("""
            INSERT INTO sync_map(entity, entity_key, target, target_id, fingerprint) VALUES('item', ?, ?, ?, ?)
            ON CONFLICT(entity, entity_key, target) DO UPDATE SET target_id = excluded.target_id, fingerprint = excluded.fingerprint
            """, [key, target, targetId, fingerprint])
    }

    func removeSyncEntry(target: String, key: String) {
        _ = try? db.execute("DELETE FROM sync_map WHERE target = ? AND entity_key = ?", [target, key])
    }

    func clearSync(target: String) { _ = try? db.execute("DELETE FROM sync_map WHERE target = ?", [target]) }

    /// Everything that should appear in the student's system calendar, keyed stably.
    func calendarExportItems(days: Int = 60, now: Date = Date()) -> [(key: String, title: String, start: Date, end: Date, location: String?, notes: String?, alarmMinutes: Int?)] {
        let tz = timezone
        let today = LocalDate(now, tz: tz)
        var out: [(String, String, Date, Date, String?, String?, Int?)] = []
        let courses = courseMap()
        for o in occurrences(from: today.adding(days: -1), to: today.adding(days: days), includeBusy: false)
        where o.status != .canceled && !o.allDay {
            out.append(("occ:\(o.key)", o.title, o.start, o.end, o.location, o.note, 10))
        }
        for a in assignments() where a.isOpen {
            guard let due = a.dueAt, due > now.adding(days: -1), due < now.adding(days: Double(days)) else { continue }
            let c = a.courseId.flatMap { courses[$0]?.shortName }.map { "\($0): " } ?? ""
            let w = a.weightPct.map { " (\(Int($0))%)" } ?? ""
            out.append(("asg:\(a.id)", "Due: \(c)\(a.title)\(w)", due.adding(minutes: -15), due, nil, a.url, 24 * 60))
        }
        for b in studyBlocks(from: now.adding(days: -1), to: now.adding(days: Double(days)), statuses: ["planned"]) {
            out.append(("blk:\(b.id)", "Study: \(b.focus ?? "")", b.plannedStart, b.end, nil, nil, 5))
        }
        return out
    }
}
