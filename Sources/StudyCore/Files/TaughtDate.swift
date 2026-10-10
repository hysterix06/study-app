import Foundation

/// When a file was taught, worked out from what it's called. "Week 3" is the third week of the term (the course's first
/// class that week); "Lecture 5" is the course's fifth class. Nothing else counts: a whole course often arrives on day
/// one, so an import date says nothing about when something was taught.
public enum TaughtDate {
    public static func week(in s: String) -> Int? {
        number(in: FileSorter.clean(s), #"(?<![a-z0-9])(?:week|wk|w|woche|semaine|semana|settimana)\s?0?(\d{1,2})(?![0-9])"#)
    }

    public static func session(in s: String) -> Int? {
        number(in: FileSorter.clean(s),
               #"(?<![a-z0-9])(?:lecture|lec|session|class|lesson|l|vl|vorlesung|sitzung|cours|seance|clase|sesion|lezione|hoorcollege|college|aula)\s?0?(\d{1,2})(?![0-9])"#)
    }

    static func number(in s: String, _ pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s), let n = Int(s[r]), (1...30).contains(n) else { return nil }
        return n
    }

    /// - Parameters:
    ///   - texts: the Moodle section, module name, title and filename, most telling first.
    ///   - termStart: the first day of the term.
    ///   - classDates: the course's class days this term, in order.
    public static func date(texts: [String?], termStart: LocalDate?, classDates: [LocalDate]) -> LocalDate? {
        for t in texts.compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if let n = week(in: t), let start = termStart {
                let weekStart = start.startOfWeek().adding(days: (n - 1) * 7)
                let weekEnd = weekStart.adding(days: 6)
                return classDates.first { $0 >= weekStart && $0 <= weekEnd } ?? weekStart
            }
            if let n = session(in: t), classDates.count >= n { return classDates[n - 1] }
        }
        return nil
    }
}
