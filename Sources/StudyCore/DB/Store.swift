import Foundation

/// The only place SQL lives (§0.5). Used by both the app and the MCP server.
public final class StudyStore: @unchecked Sendable {
    public let db: Database
    public let paths: AppPaths
    public let actor: String // "app" | "mcp" | "sync"

    public init(db: Database, paths: AppPaths, actor: String = "app") {
        self.db = db; self.paths = paths; self.actor = actor
    }

    /// Opens (and for the app, migrates) the database at the configured path.
    public static func open(paths: AppPaths = AppPaths(), actor: String = "app", migrate: Bool = true) throws -> StudyStore {
        let db = try Database(path: paths.database.path)
        if migrate { try Migrations.migrate(db) } else { try Migrations.check(db) }
        paths.ensureFolders()
        return StudyStore(db: db, paths: paths, actor: actor)
    }

    public static func inMemory(root: URL? = nil) throws -> StudyStore {
        let db = try Database(path: ":memory:")
        try Migrations.migrate(db)
        let r = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString)")
        let paths = AppPaths(database: URL(fileURLWithPath: ":memory:"), root: r)
        paths.ensureFolders()
        return StudyStore(db: db, paths: paths)
    }

    // MARK: Settings

    public func setting(_ key: String) -> String? {
        try? db.scalarString("SELECT value FROM settings WHERE key = ?", [key])
    }
    public func setSetting(_ key: String, _ value: String?) {
        if let value {
            _ = try? db.execute("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
        } else {
            _ = try? db.execute("DELETE FROM settings WHERE key = ?", [key])
        }
    }
    public func boolSetting(_ key: String, default def: Bool = false) -> Bool {
        guard let v = setting(key) else { return def }
        return v == "1" || v == "true"
    }
    public func setBool(_ key: String, _ v: Bool) { setSetting(key, v ? "1" : "0") }
    public func intSetting(_ key: String, default def: Int) -> Int { setting(key).flatMap(Int.init) ?? def }
    public func doubleSetting(_ key: String, default def: Double) -> Double { setting(key).flatMap(Double.init) ?? def }

    public var timezone: TimeZone {
        setting("default_timezone").flatMap(TimeZone.init(identifier:)) ?? .current
    }
    public var defaultDueTime: LocalTime { setting("default_due_time").flatMap(LocalTime.init) ?? LocalTime(hour: 23, minute: 59) }
    public var weekStartsOn: Int { intSetting("week_starts_on", default: 1) }
    public var dayFirstDates: Bool { boolSetting("day_first_dates", default: !(Locale.current.region?.identifier == "US")) }

    public var plannerSettings: PlannerSettings {
        var s = PlannerSettings()
        s.windowStart = setting("study_window_start").flatMap(LocalTime.init) ?? s.windowStart
        s.windowEnd = setting("study_window_end").flatMap(LocalTime.init) ?? s.windowEnd
        s.maxMinutesPerDay = intSetting("max_study_minutes_per_day", default: s.maxMinutesPerDay)
        s.defaultHoursExam = doubleSetting("default_hours_exam", default: s.defaultHoursExam)
        s.defaultHoursOther = doubleSetting("default_hours_other", default: s.defaultHoursOther)
        return s
    }

    // MARK: Audit

    public func audit(_ action: String, entity: String? = nil, id: Int? = nil, detail: Any? = nil) {
        var text: String?
        if let detail {
            let s = detail as? String ?? JSON.string(detail)
            text = String(s.prefix(500))
        }
        _ = try? db.execute("INSERT INTO audit_log(actor, action, entity, entity_id, detail) VALUES(?,?,?,?,?)", [actor, action, entity, id, text])
    }

    public func recentAudit(actor: String? = nil, limit: Int = 20) -> [(at: Date, actor: String, action: String, entity: String?, detail: String?)] {
        let rows = (try? db.query("SELECT * FROM audit_log \(actor != nil ? "WHERE actor = ?" : "") ORDER BY id DESC LIMIT ?",
                                  actor != nil ? [actor, limit] : [limit])) ?? []
        return rows.map { (ISO.parse($0.str("at")) ?? Date(), $0.str("actor"), $0.str("action"), $0.string("entity"), $0.string("detail")) }
    }

    // MARK: Backups

    /// Daily VACUUM INTO copies, keeping the newest `keep` (§3.3).
    @discardableResult
    public func backup(reason: String = "daily", keep: Int = 14) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = paths.backups.appendingPathComponent("study-\(f.string(from: Date()))-\(reason).db")
        try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        try db.vacuumInto(url.path)
        pruneBackups(keep: keep)
        return url
    }

    public func latestBackupDate() -> Date? {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "db" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    public func backupIfOlderThan(hours: Double, reason: String) {
        if let last = latestBackupDate(), Date().timeIntervalSince(last) < hours * 3600 { return }
        _ = try? backup(reason: reason)
    }

    func pruneBackups(keep: Int) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "db" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for f in files.dropFirst(keep) { try? FileManager.default.removeItem(at: f) }
    }
}
