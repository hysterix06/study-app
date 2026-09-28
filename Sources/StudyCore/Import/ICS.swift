import Foundation

/// A small, tolerant iCalendar (RFC 5545) reader covering what school calendars use:
/// VEVENT, DTSTART/DTEND/DURATION, RRULE, EXDATE, RECURRENCE-ID, STATUS, TZID (IANA or Windows names).
public struct ICSDateTime: Hashable {
    public var date: LocalDate
    public var time: LocalTime?
    public var second: Int = 0
    public var tzid: String?
    public var isUTC: Bool

    public var isDateOnly: Bool { time == nil }

    public func timeZone(default def: TimeZone) -> TimeZone {
        if isUTC { return TimeZone(identifier: "UTC")! }
        if let tzid, let tz = ICS.timeZone(for: tzid) { return tz }
        return def
    }

    public func instant(default def: TimeZone) -> Date {
        let tz = timeZone(default: def)
        return date.at(time ?? LocalTime(hour: 0, minute: 0), tz: tz).addingTimeInterval(Double(second))
    }

    /// Local date and time in the target zone.
    public func local(in target: TimeZone, default def: TimeZone) -> (LocalDate, LocalTime) {
        if isDateOnly { return (date, LocalTime(hour: 0, minute: 0)) }
        let i = instant(default: def)
        return (LocalDate(i, tz: target), LocalTime(i, tz: target))
    }
}

public struct RRule: Hashable {
    public var freq: String
    public var interval: Int = 1
    public var byDay: [Int] = []
    public var until: ICSDateTime?
    public var count: Int?
    public var raw: String
}

public struct ICSEvent: Hashable {
    public var uid: String
    public var summary: String = ""
    public var description: String?
    public var location: String?
    public var status: String?
    public var categories: [String] = []
    public var dtstart: ICSDateTime?
    public var dtend: ICSDateTime?
    public var duration: TimeInterval?
    public var rrule: RRule?
    public var exdates: [ICSDateTime] = []
    public var recurrenceId: ICSDateTime?
    public var url: String?

    public var isCancelled: Bool { status?.uppercased() == "CANCELLED" }

    public func endInstant(default tz: TimeZone) -> Date? {
        guard let dtstart else { return nil }
        if let dtend { return dtend.instant(default: tz) }
        if let duration { return dtstart.instant(default: tz).addingTimeInterval(duration) }
        return dtstart.isDateOnly ? dtstart.instant(default: tz).adding(days: 1) : dtstart.instant(default: tz).adding(minutes: 60)
    }
}

public enum ICSError: Error, CustomStringConvertible {
    case notCalendar
    public var description: String { "This file is not an iCalendar (.ics) file." }
}

public enum ICS {
    public static func parse(_ text: String) throws -> [ICSEvent] {
        guard text.range(of: "BEGIN:VCALENDAR", options: .caseInsensitive) != nil else { throw ICSError.notCalendar }
        // Unfold: a line starting with space or tab continues the previous one.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = raw.first, (f == " " || f == "\t"), !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }

        var events: [ICSEvent] = []
        var current: ICSEvent?
        var depth = 0 // nested components inside VEVENT (VALARM)
        var autoUID = 0
        for line in lines where !line.isEmpty {
            guard let (name, params, value) = parseLine(line) else { continue }
            if name == "BEGIN" {
                if value.uppercased() == "VEVENT" { current = ICSEvent(uid: ""); depth = 0 }
                else if current != nil { depth += 1 }
                continue
            }
            if name == "END" {
                if value.uppercased() == "VEVENT", var ev = current {
                    if ev.uid.isEmpty { autoUID += 1; ev.uid = "auto-\(autoUID)-\(ev.summary.hashValue)" }
                    if ev.dtstart != nil { events.append(ev) }
                    current = nil
                } else if current != nil { depth -= 1 }
                continue
            }
            guard current != nil, depth == 0 else { continue }
            switch name {
            case "UID": current!.uid = value
            case "SUMMARY": current!.summary = unescape(value)
            case "DESCRIPTION": current!.description = unescape(value)
            case "LOCATION": current!.location = unescape(value).nilIfEmpty
            case "STATUS": current!.status = value
            case "URL": current!.url = value
            case "CATEGORIES": current!.categories += unescape(value).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            case "DTSTART": current!.dtstart = parseDateTime(value, params: params)
            case "DTEND": current!.dtend = parseDateTime(value, params: params)
            case "DUE": if current!.dtstart == nil { current!.dtstart = parseDateTime(value, params: params) }
            case "DURATION": current!.duration = parseDuration(value)
            case "RRULE": current!.rrule = parseRRule(value, params: params)
            case "EXDATE":
                for part in value.split(separator: ",") {
                    if let d = parseDateTime(String(part), params: params) { current!.exdates.append(d) }
                }
            case "RECURRENCE-ID": current!.recurrenceId = parseDateTime(value, params: params)
            default: break
            }
        }
        return events
    }

    static func parseLine(_ line: String) -> (String, [String: String], String)? {
        // Split at the first colon that is not inside double quotes.
        var inQuotes = false
        var splitIndex: String.Index?
        for idx in line.indices {
            let ch = line[idx]
            if ch == "\"" { inQuotes.toggle() }
            else if ch == ":" && !inQuotes { splitIndex = idx; break }
        }
        guard let splitIndex else { return nil }
        let head = line[..<splitIndex]
        let value = String(line[line.index(after: splitIndex)...])
        let parts = head.split(separator: ";", omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (first.uppercased(), params, value)
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\", let n = it.next() {
                switch n {
                case "n", "N": out.append("\n")
                default: out.append(n)
                }
            } else { out.append(c) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseDateTime(_ raw: String, params: [String: String] = [:]) -> ICSDateTime? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        let digits = v.filter(\.isNumber)
        guard digits.count >= 8 else { return nil }
        let y = Int(digits.prefix(4))!, m = Int(digits.dropFirst(4).prefix(2))!, d = Int(digits.dropFirst(6).prefix(2))!
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        let date = LocalDate(year: y, month: m, day: d)
        let isDateOnly = params["VALUE"]?.uppercased() == "DATE" || !v.contains("T")
        if isDateOnly { return ICSDateTime(date: date, time: nil, tzid: nil, isUTC: false) }
        let t = digits.dropFirst(8)
        let hh = Int(t.prefix(2)) ?? 0, mm = Int(t.dropFirst(2).prefix(2)) ?? 0, ss = Int(t.dropFirst(4).prefix(2)) ?? 0
        return ICSDateTime(date: date, time: LocalTime(hour: hh, minute: mm), second: ss, tzid: params["TZID"], isUTC: v.hasSuffix("Z"))
    }

    static func parseDuration(_ v: String) -> TimeInterval? {
        // P1DT2H30M, PT90M, P1W
        guard let re = try? NSRegularExpression(pattern: #"^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#) else { return nil }
        let ns = v as NSString
        guard let m = re.firstMatch(in: v, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> Double { let r = m.range(at: i); return r.location == NSNotFound ? 0 : Double(ns.substring(with: r)) ?? 0 }
        let total = g(2) * 604800 + g(3) * 86400 + g(4) * 3600 + g(5) * 60 + g(6)
        return total
    }

    static func parseRRule(_ v: String, params: [String: String]) -> RRule {
        var r = RRule(freq: "", raw: v)
        let dayMap = ["MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6, "SU": 7]
        for part in v.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0].uppercased() {
            case "FREQ": r.freq = kv[1].uppercased()
            case "INTERVAL": r.interval = max(1, Int(kv[1]) ?? 1)
            case "COUNT": r.count = Int(kv[1])
            case "UNTIL": r.until = parseDateTime(kv[1])
            case "BYDAY":
                r.byDay = kv[1].split(separator: ",").compactMap { tok in
                    let letters = tok.filter(\.isLetter).uppercased()
                    // Skip ordinal forms like 1MO (monthly rules).
                    if tok.contains(where: \.isNumber) { return nil }
                    return dayMap[letters]
                }
            default: break
            }
        }
        return r
    }

    /// IANA identifiers pass through; common Windows (Outlook/Exchange) names are mapped.
    public static func timeZone(for tzid: String) -> TimeZone? {
        let cleaned = tzid.trimmingCharacters(in: CharacterSet(charactersIn: "\"/ "))
        if let tz = TimeZone(identifier: cleaned) { return tz }
        if let mapped = windowsZones[cleaned], let tz = TimeZone(identifier: mapped) { return tz }
        // "(UTC+01:00) Amsterdam, Berlin, …" style names from some exports.
        for (key, iana) in windowsZones where cleaned.localizedCaseInsensitiveContains(key) { return TimeZone(identifier: iana) }
        return nil
    }

    static let windowsZones: [String: String] = [
        "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
        "Central Europe Standard Time": "Europe/Budapest", "Central European Standard Time": "Europe/Warsaw",
        "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
        "E. Europe Standard Time": "Europe/Chisinau", "FLE Standard Time": "Europe/Kiev", "GTB Standard Time": "Europe/Bucharest",
        "Russian Standard Time": "Europe/Moscow", "Turkey Standard Time": "Europe/Istanbul", "Israel Standard Time": "Asia/Jerusalem",
        "South Africa Standard Time": "Africa/Johannesburg", "Egypt Standard Time": "Africa/Cairo",
        "Arabian Standard Time": "Asia/Dubai", "Arab Standard Time": "Asia/Riyadh", "India Standard Time": "Asia/Kolkata",
        "China Standard Time": "Asia/Shanghai", "Singapore Standard Time": "Asia/Singapore", "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul", "SE Asia Standard Time": "Asia/Bangkok", "Taipei Standard Time": "Asia/Taipei",
        "AUS Eastern Standard Time": "Australia/Sydney", "E. Australia Standard Time": "Australia/Brisbane",
        "W. Australia Standard Time": "Australia/Perth", "New Zealand Standard Time": "Pacific/Auckland",
        "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver", "US Mountain Standard Time": "America/Phoenix",
        "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu", "Atlantic Standard Time": "America/Halifax",
        "SA Pacific Standard Time": "America/Bogota", "Pacific SA Standard Time": "America/Santiago",
        "E. South America Standard Time": "America/Sao_Paulo", "Argentina Standard Time": "America/Buenos_Aires",
        "Central America Standard Time": "America/Guatemala", "Mexico Standard Time": "America/Mexico_City",
        "Central Standard Time (Mexico)": "America/Mexico_City", "Canada Central Standard Time": "America/Regina",
        "UTC": "UTC", "Coordinated Universal Time": "UTC", "Morocco Standard Time": "Africa/Casablanca",
        "W. Central Africa Standard Time": "Africa/Lagos", "E. Africa Standard Time": "Africa/Nairobi",
        "Amsterdam": "Europe/Amsterdam", "Madrid": "Europe/Madrid", "Brussels": "Europe/Brussels", "Paris": "Europe/Paris",
        "Zurich": "Europe/Zurich", "Bern": "Europe/Zurich", "Rome": "Europe/Rome", "Vienna": "Europe/Vienna",
        "Stockholm": "Europe/Stockholm", "Dublin": "Europe/Dublin", "London": "Europe/London", "Lisbon": "Europe/Lisbon",
    ]

    // MARK: Writing (used to publish the study calendar)

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
    }

    public static func utcStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }
}

extension String {
    var nilIfEmpty: String? { let t = trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
}
