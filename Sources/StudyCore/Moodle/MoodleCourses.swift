import Foundation

/// Which Moodle courses are this term's, and what to call them.
public enum MoodleCourses {
    /// "BHC1-09-158 Mkt for the Hosp Ind 26.2" → "Mkt for the Hosp Ind", code "BHC1-09-158".
    public static func names(shortname: String, fullname: String) -> (name: String, code: String?) {
        let code = leadingCode(shortname) ?? leadingCode(fullname)
        var name = fullname.isEmpty ? shortname : fullname
        if let lead = leadingCode(name) { name = String(name.dropFirst(lead.count)) }
        if let r = name.range(of: termPattern, options: .regularExpression) { name.removeSubrange(r) }
        name = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|").union(.whitespacesAndNewlines))
        return (name.isEmpty ? (code ?? fullname) : name, code)
    }

    static let codePattern = #"^([A-Z]{2,}[A-Z0-9]*(?:-[A-Z0-9]+)+|[A-Z]{2,5}\s?\d{2,4}[A-Z]?)(?=\s|$)"#
    static let termPattern = #"\s*\(?(?<![\d.])(\d{2}|\d{4})\.(\d)(?![\d.])\)?\s*$"#

    static func leadingCode(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: codePattern, options: .regularExpression) else { return nil }
        return String(t[r])
    }

    /// The term a course belongs to when its name ends with one, such as "26.2" or "2026.1".
    public static func term(_ c: MoodleCourseInfo) -> Int? {
        for s in [c.fullname, c.shortname] {
            guard let r = s.range(of: termPattern, options: .regularExpression) else { continue }
            let digits = s[r].filter { $0.isNumber || $0 == "." }.split(separator: ".")
            guard digits.count == 2, var year = Int(digits[0]), let part = Int(digits[1]) else { continue }
            if year < 100 { year += 2000 }
            return year * 10 + part
        }
        return nil
    }

    /// This term's courses. When course names carry a term ("26.2"), the latest term wins, whatever the dates say
    /// (some schools copy last year's course with its dates). Otherwise the dates decide, or a visit in the last month.
    public static func current(_ courses: [MoodleCourseInfo], now: Date = Date()) -> [MoodleCourseInfo] {
        let latest = courses.compactMap(term).max()
        let day = 86_400.0
        return courses.filter { c in
            if let t = term(c) { return t == latest }
            if let s = c.start, let e = c.end, s <= now.addingTimeInterval(30 * day), e >= now { return true }
            if let s = c.start, c.end == nil, s <= now.addingTimeInterval(30 * day), s >= now.addingTimeInterval(-180 * day) { return true }
            if let a = c.lastAccess, a >= now.addingTimeInterval(-30 * day) { return true }
            return false
        }
    }

    /// Pages that aren't taught courses (orientation, student services, the library). Added hidden.
    public static func looksAdministrative(_ name: String) -> Bool {
        name.range(of: #"(?i)\b(induction|orientation|academic services|student services|library|exam training|governance|welcome week|onboarding|noticeboard|announcements)\b"#,
                   options: .regularExpression) != nil
    }
}
