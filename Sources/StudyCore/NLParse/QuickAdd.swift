import Foundation

public struct QuickAddResult: Equatable {
    public struct Piece: Equatable, Hashable {
        public enum Kind: String { case course, due, weight, hours, kind }
        public var kind: Kind
        public var text: String
    }
    public var title: String
    public var courseId: Int?
    public var courseCandidates: [Int]
    public var dueAt: Date?
    public var hasTime: Bool
    public var weightPct: Double?
    public var estHours: Double?
    public var kind: AssignmentKind
    public var pieces: [Piece]

    /// Never save silently with a guessed course (§7.5).
    public var needsCoursePick: Bool { courseId == nil }
}

public struct QuickAddParser {
    public var courses: [Course]
    public var now: Date
    public var tz: TimeZone
    public var defaultDueTime: LocalTime
    public var dayFirst: Bool

    public init(courses: [Course], now: Date = Date(), tz: TimeZone = .current,
                defaultDueTime: LocalTime = LocalTime(hour: 23, minute: 59), dayFirst: Bool = true) {
        self.courses = courses; self.now = now; self.tz = tz; self.defaultDueTime = defaultDueTime; self.dayFirst = dayFirst
    }

    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4, "may": 5,
        "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]
    static let weekdays: [String: Int] = [
        "mon": 1, "monday": 1, "tue": 2, "tues": 2, "tuesday": 2, "wed": 3, "weds": 3, "wednesday": 3,
        "thu": 4, "thur": 4, "thurs": 4, "thursday": 4, "fri": 5, "friday": 5, "sat": 6, "saturday": 6,
        "sun": 7, "sunday": 7,
    ]
    static let kindWords: [(String, AssignmentKind)] = [
        ("midterm", .exam), ("final exam", .exam), ("exam", .exam), ("quiz", .quiz), ("test", .quiz),
        ("presentation", .presentation), ("pitch", .presentation), ("reading", .reading), ("read ", .reading),
        ("report", .report), ("essay", .report), ("project", .project), ("case study", .case_), ("case", .case_),
        ("lab", .lab), ("practical", .lab),
    ]

    public func parse(_ input: String) -> QuickAddResult {
        var work = " " + input + " "
        var pieces: [QuickAddResult.Piece] = []
        let today = LocalDate(now, tz: tz)
        var date: LocalDate?
        var time: LocalTime?

        func take(_ pattern: String, _ handler: ([String]) -> Bool) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            let ns = work as NSString
            guard let m = re.firstMatch(in: work, range: NSRange(location: 0, length: ns.length)) else { return }
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            if handler(groups) {
                work = ns.replacingCharacters(in: m.range, with: " ")
            }
        }

        // Weight "30%" and estimate "6h" / "90 min".
        var weight: Double?
        take(#"(?<![\w.])(\d+(?:\.\d+)?)\s*%"#) { g in
            weight = Double(g[1]); pieces.append(.init(kind: .weight, text: "\(g[1])%")); return true
        }
        var hours: Double?
        take(#"(?<![\w.:])(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)(?![\w])"#) { g in
            hours = Double(g[1]); pieces.append(.init(kind: .hours, text: "\(g[1]) h")); return true
        }
        if hours == nil {
            take(#"(?<![\w.:])(\d+)\s*(?:m|min|mins|minutes)(?![\w])"#) { g in
                guard let m = Double(g[1]) else { return false }
                hours = (m / 60 * 100).rounded() / 100; pieces.append(.init(kind: .hours, text: "\(g[1]) min")); return true
            }
        }

        // Dates.
        take(#"\b(\d{4})-(\d{2})-(\d{2})\b"#) { g in
            date = LocalDate("\(g[1])-\(g[2])-\(g[3])"); return date != nil
        }
        if date == nil {
            take(#"(?<![\d:])(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2,4}))?(?![\d:])"#) { g in
                guard let a = Int(g[1]), let b = Int(g[2]) else { return false }
                var (d, m) = dayFirst ? (a, b) : (b, a)
                if m > 12 && d <= 12 { swap(&d, &m) }
                guard (1...12).contains(m), (1...31).contains(d) else { return false }
                var y = today.year
                if let yy = Int(g[3]) { y = yy < 100 ? 2000 + yy : yy }
                var cand = LocalDate(year: y, month: m, day: d)
                if g[3].isEmpty && cand < today { cand = LocalDate(year: y + 1, month: m, day: d) }
                date = cand; return true
            }
        }
        let monthAlt = Self.months.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        if date == nil {
            // "Oct 12", "October 12th", "Oct 12 2026"
            take(#"\b("# + monthAlt + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#) { g in
                guard let m = Self.months[g[1].lowercased()], let d = Int(g[2]), (1...31).contains(d) else { return false }
                date = resolve(month: m, day: d, year: Int(g[3]), today: today); return true
            }
        }
        if date == nil {
            // "12 Oct", "12th of October 2026"
            take(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?("# + monthAlt + #")\.?(?:\s+(\d{4}))?\b"#) { g in
                guard let m = Self.months[g[2].lowercased()], let d = Int(g[1]), (1...31).contains(d) else { return false }
                date = resolve(month: m, day: d, year: Int(g[3]), today: today); return true
            }
        }
        if date == nil {
            take(#"\b(today|tonight|tomorrow|tmrw|tmr)\b"#) { g in
                switch g[1].lowercased() {
                case "today": date = today
                case "tonight": date = today; if time == nil { time = LocalTime(hour: 21, minute: 0) }
                default: date = today.adding(days: 1)
                }
                return true
            }
        }
        if date == nil {
            take(#"\bin\s+(\d+|a|an|one|two|three)\s+(day|days|week|weeks)\b"#) { g in
                let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3]
                let n = Int(g[1]) ?? words[g[1].lowercased()] ?? 1
                date = today.adding(days: g[2].lowercased().hasPrefix("week") ? n * 7 : n); return true
            }
        }
        var weekdayMatched = false
        if date == nil {
            let alt = Self.weekdays.keys.sorted { $0.count > $1.count }.joined(separator: "|")
            take(#"\b(next\s+|this\s+)?("# + alt + #")\b\.?"#) { g in
                guard let wd = Self.weekdays[g[2].lowercased()] else { return false }
                var d = today.adding(days: (wd - today.weekday + 7) % 7)
                if g[1].lowercased().hasPrefix("next") { d = d.adding(days: 7) }
                date = d; weekdayMatched = true; return true
            }
        }

        // Times.
        take(#"(?<![\w:])(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)(?![\w])"#) { g in
            guard var h = Int(g[1]), (1...12).contains(h) else { return false }
            let m = Int(g[2]) ?? 0
            let pm = g[3].lowercased().hasPrefix("p")
            if pm && h < 12 { h += 12 }
            if !pm && h == 12 { h = 0 }
            time = LocalTime(hour: h, minute: m); return true
        }
        if time == nil {
            take(#"(?<![\w:./])([01]?\d|2[0-3])[h:]([0-5]\d)(?![\w:])"#) { g in
                guard let h = Int(g[1]), let m = Int(g[2]) else { return false }
                time = LocalTime(hour: h, minute: m); return true
            }
        }
        if time == nil {
            take(#"\b(noon|midday|midnight|eod|end of day)\b"#) { g in
                switch g[1].lowercased() {
                case "noon", "midday": time = LocalTime(hour: 12, minute: 0)
                default: time = LocalTime(hour: 23, minute: 59)
                }
                return true
            }
        }
        if time == nil && date != nil {
            take(#"\bat\s+(\d{1,2})\b"#) { g in
                guard var h = Int(g[1]), (0...23).contains(h) else { return false }
                if (1...7).contains(h) { h += 12 }
                time = LocalTime(hour: h, minute: 0); return true
            }
        }

        // Resolve due.
        var due: Date?
        if date != nil || time != nil {
            var d = date ?? today
            let t = time ?? defaultDueTime
            if date == nil, d.at(t, tz: tz) < now { d = d.adding(days: 1) }
            if weekdayMatched, d == today, time != nil, d.at(t, tz: tz) < now { d = d.adding(days: 7) }
            due = d.at(t, tz: tz)
            let f = DateFormatter()
            f.timeZone = tz
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = time == nil ? "EEE d MMM" : "EEE d MMM, HH:mm"
            pieces.append(.init(kind: .due, text: f.string(from: due!)))
        }

        // Connector words left behind by dates ("due fri", "by 5pm", "on Oct 12").
        for _ in 0..<2 {
            take(#"\s(due|by|on|at)\s*$"#) { _ in true }
            take(#"\s(due|by|on|at)\s+(?=(for|\s|$))"#) { _ in true }
        }

        // Course: code or alias as a whole token (stripped); otherwise name matches (kept in title).
        var courseId: Int?
        var candidates: [Int] = []
        let active = courses.filter { !$0.archived }
        for c in active {
            var keys: [String] = c.aliasList
            if let code = c.code, !code.isEmpty { keys.insert(code, at: 0) }
            for key in keys {
                let spaced = NSRegularExpression.escapedPattern(for: key).replacingOccurrences(of: "\\ ", with: "\\s*")
                let codeSpaced = key.range(of: #"^[A-Za-z]+\d+"#, options: .regularExpression) != nil
                    ? key.replacingOccurrences(of: #"([A-Za-z]+)(\d+)"#, with: "$1\\\\s?$2", options: .regularExpression)
                    : spaced
                var matched = false
                take(#"(?<![\w-])#?(?:"# + codeSpaced + #")(?![\w-])"#) { _ in matched = true; return true }
                if matched { if !candidates.contains(c.id) { candidates.append(c.id) }; break }
            }
        }
        if candidates.isEmpty {
            let lowered = work.lowercased()
            for c in active {
                let name = c.name.lowercased()
                if lowered.contains(name) { candidates.append(c.id); continue }
                let firstWord = name.split(separator: " ").first.map(String.init) ?? name
                if firstWord.count >= 5, lowered.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: firstWord) + #"\b"#, options: .regularExpression) != nil {
                    candidates.append(c.id)
                }
            }
            // A name match is a suggestion only when unambiguous.
            if candidates.count == 1 { courseId = candidates[0] }
        } else if candidates.count == 1 {
            courseId = candidates[0]
        }
        if let courseId, let c = courses.first(where: { $0.id == courseId }) {
            pieces.insert(.init(kind: .course, text: c.displayName), at: 0)
        }

        // Kind keywords stay in the title.
        var kind = AssignmentKind.assignment
        let lowerTitle = " " + work.lowercased() + " "
        for (word, k) in Self.kindWords {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: word.trimmingCharacters(in: .whitespaces)) + #"\b"#
            if lowerTitle.range(of: pattern, options: .regularExpression) != nil { kind = k; break }
        }
        if kind != .assignment { pieces.append(.init(kind: .kind, text: kind.label)) }

        let title = work.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;.-–—"))
        return QuickAddResult(title: title.isEmpty ? input.trimmingCharacters(in: .whitespaces) : title,
                              courseId: courseId, courseCandidates: candidates, dueAt: due, hasTime: time != nil,
                              weightPct: weight, estHours: hours, kind: kind, pieces: pieces)
    }

    func resolve(month: Int, day: Int, year: Int?, today: LocalDate) -> LocalDate {
        if let year { return LocalDate(year: year, month: month, day: day) }
        let cand = LocalDate(year: today.year, month: month, day: day)
        return cand < today ? LocalDate(year: today.year + 1, month: month, day: day) : cand
    }
}
