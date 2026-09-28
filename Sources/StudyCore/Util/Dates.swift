import Foundation

/// ISO 8601 helpers. Instants are always stored in UTC ("…Z") so that text ordering equals time ordering.
public enum ISO {
    private static let utcFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    public static func instant(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return utcFormatter.string(from: date)
    }

    /// Formats an instant with the offset of the given zone, e.g. 2026-10-06T09:00:00+02:00.
    public static func instant(_ date: Date, in tz: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = tz
        return f.string(from: date)
    }

    /// Accepts offsets, Z, fractional seconds, and "YYYY-MM-DDTHH:MM" (treated as local in `tz`).
    public static func parse(_ s: String, tz: TimeZone = .current) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        lock.lock()
        let a = utcFormatter.date(from: t) ?? fractional.date(from: t)
        lock.unlock()
        if let a { return a }
        // "2026-10-06T09:00" or "2026-10-06 09:00" or "2026-10-06T09:00:00" (no offset)
        let normalized = t.replacingOccurrences(of: " ", with: "T")
        let parts = normalized.split(separator: "T")
        if parts.count == 2, let d = LocalDate(String(parts[0])) {
            let timePart = String(parts[1].prefix(5))
            if let lt = LocalTime(timePart) { return d.at(lt, tz: tz) }
        }
        if let d = LocalDate(t) { return d.at(LocalTime(hour: 0, minute: 0), tz: tz) }
        return nil
    }
}

public let gregorianUTC: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.firstWeekday = 2
    return c
}()

public func calendar(in tz: TimeZone) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    c.firstWeekday = 2
    return c
}

/// A calendar date without time or zone, "YYYY-MM-DD".
public struct LocalDate: Hashable, Comparable, Codable, CustomStringConvertible {
    public let year: Int, month: Int, day: Int

    public init(year: Int, month: Int, day: Int) {
        // Normalize via calendar so day overflow rolls correctly.
        let comps = DateComponents(year: year, month: month, day: day)
        let d = gregorianUTC.date(from: comps)!
        let c = gregorianUTC.dateComponents([.year, .month, .day], from: d)
        self.year = c.year!; self.month = c.month!; self.day = c.day!
    }

    public init?(_ s: String) {
        let p = s.prefix(10).split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d), p[0].count == 4 else { return nil }
        self.init(year: y, month: m, day: d)
        if self.month != m { return nil } // e.g. 2026-02-31
    }

    /// The local date of an instant in a zone.
    public init(_ date: Date, tz: TimeZone) {
        let c = calendar(in: tz).dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public static func today(tz: TimeZone = .current, now: Date = Date()) -> LocalDate { LocalDate(now, tz: tz) }

    public var string: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { string }

    public var utcMidnight: Date { gregorianUTC.date(from: DateComponents(year: year, month: month, day: day))! }

    public func adding(days: Int) -> LocalDate {
        LocalDate(year: year, month: month, day: day + days)
    }
    public func adding(months: Int) -> LocalDate {
        let d = gregorianUTC.date(byAdding: .month, value: months, to: utcMidnight)!
        let c = gregorianUTC.dateComponents([.year, .month, .day], from: d)
        return LocalDate(year: c.year!, month: c.month!, day: c.day!)
    }

    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public var weekday: Int {
        let w = gregorianUTC.component(.weekday, from: utcMidnight) // 1 = Sunday
        return w == 1 ? 7 : w - 1
    }

    public func days(to other: LocalDate) -> Int {
        gregorianUTC.dateComponents([.day], from: utcMidnight, to: other.utcMidnight).day!
    }

    public func startOfWeek(weekStartsOn: Int = 1) -> LocalDate {
        let diff = (weekday - weekStartsOn + 7) % 7
        return adding(days: -diff)
    }

    public var firstOfMonth: LocalDate { LocalDate(year: year, month: month, day: 1) }

    public func at(_ time: LocalTime, tz: TimeZone) -> Date {
        let comps = DateComponents(timeZone: tz, year: year, month: month, day: day, hour: time.hour, minute: time.minute)
        return calendar(in: tz).date(from: comps)!
    }

    public static func < (a: LocalDate, b: LocalDate) -> Bool { a.string < b.string }

    public static func range(_ from: LocalDate, _ to: LocalDate) -> [LocalDate] {
        guard from <= to else { return [] }
        var out: [LocalDate] = []
        var d = from
        while d <= to { out.append(d); d = d.adding(days: 1) }
        return out
    }
}

/// A wall-clock time "HH:MM".
public struct LocalTime: Hashable, Comparable, Codable, CustomStringConvertible {
    public let hour: Int, minute: Int
    public init(hour: Int, minute: Int) {
        self.hour = max(0, min(23, hour)); self.minute = max(0, min(59, minute))
    }
    public init?(_ s: String) {
        let p = s.split(separator: ":")
        guard p.count >= 2, let h = Int(p[0]), let m = Int(p[1].prefix(2)), (0...24).contains(h), (0...59).contains(m) else { return nil }
        if h == 24 { self.init(hour: 23, minute: 59) } else { self.init(hour: h, minute: m) }
    }
    public init(minutes: Int) { self.init(hour: minutes / 60, minute: minutes % 60) }
    public init(_ date: Date, tz: TimeZone) {
        let c = calendar(in: tz).dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour!, minute: c.minute!)
    }
    public var minutes: Int { hour * 60 + minute }
    public var string: String { String(format: "%02d:%02d", hour, minute) }
    public var description: String { string }
    public static func < (a: LocalTime, b: LocalTime) -> Bool { a.minutes < b.minutes }
}

public extension Date {
    func adding(minutes: Int) -> Date { addingTimeInterval(Double(minutes) * 60) }
    func adding(hours: Double) -> Date { addingTimeInterval(hours * 3600) }
    func adding(days: Double) -> Date { addingTimeInterval(days * 86400) }
}

public enum RelativeTime {
    /// "in 2 h 10 min", "3 d ago", "now".
    public static func describe(_ date: Date, now: Date = Date()) -> String {
        let secs = date.timeIntervalSince(now)
        let past = secs < 0
        let m = Int(abs(secs) / 60)
        let text: String
        if m < 1 { return "now" }
        else if m < 60 { text = "\(m) min" }
        else if m < 60 * 24 {
            let h = m / 60, r = m % 60
            text = r == 0 || h >= 6 ? "\(h) h" : "\(h) h \(r) min"
        } else {
            let d = Int((abs(secs) / 86400).rounded())
            text = d == 1 ? "1 day" : "\(d) days"
        }
        return past ? "\(text) ago" : "in \(text)"
    }
}
