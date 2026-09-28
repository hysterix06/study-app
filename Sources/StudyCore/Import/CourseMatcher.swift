import Foundation

/// Suggests which course a piece of text (calendar title, filename, first slide) belongs to.
public enum CourseMatcher {
    static func normalize(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"[_\-\.]+"#, with: " ", options: .regularExpression)
    }

    static func compact(_ s: String) -> String { normalize(s).replacingOccurrences(of: " ", with: "") }

    /// Scores each course; higher is better. Code matches beat names, names beat single words.
    public static func scores(_ text: String, courses: [Course]) -> [(course: Course, score: Int)] {
        let norm = " " + normalize(text) + " "
        let comp = compact(text)
        var out: [(Course, Int)] = []
        for c in courses where !c.archived {
            var score = 0
            if let code = c.code, !code.isEmpty {
                let cc = compact(code)
                if cc.count >= 3, comp.contains(cc) { score += 100 }
            }
            for alias in c.aliasList where alias.count >= 2 {
                let a = normalize(alias)
                if norm.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: a) + #"\b"#, options: .regularExpression) != nil { score += 80 }
            }
            let name = normalize(c.name)
            if norm.contains(name) { score += 60 }
            else {
                let words = name.split(separator: " ").filter { $0.count >= 4 && !stopWords.contains(String($0)) }
                let hits = words.filter { norm.contains(" \($0)") }.count
                if !words.isEmpty && hits > 0 { score += Int(40.0 * Double(hits) / Double(words.count)) }
            }
            if score > 0 { out.append((c, score)) }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    public static func best(_ text: String, courses: [Course], minimum: Int = 30) -> Course? {
        let s = scores(text, courses: courses)
        guard let top = s.first, top.score >= minimum else { return nil }
        if s.count > 1 && s[1].score == top.score { return nil }
        return top.course
    }

    static let stopWords: Set<String> = ["introduction", "principles", "management", "with", "from", "into", "hospitality", "and", "the"]

    /// "HM 210 Revenue Management" → "HM210"
    public static func extractCode(_ s: String) -> String? {
        guard let r = s.range(of: #"\b[A-Z]{2,5}\s?-?\d{2,4}[A-Z]?\b"#, options: .regularExpression) else { return nil }
        return s[r].replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
    }

    /// Titles that look like deadlines (§6.2).
    public static func looksLikeDeadline(_ title: String) -> Bool {
        let t = title.lowercased()
        let words = ["assignment", "due", "deadline", "submit", "submission", "exam", "quiz", "test", "hand in", "hand-in",
                     "opens", "closes", "turnitin", "report", "presentation"]
        return words.contains { t.contains($0) }
    }

    public static func guessKind(_ title: String) -> AssignmentKind {
        let t = title.lowercased()
        if t.contains("exam") || t.contains("midterm") { return .exam }
        if t.contains("quiz") || t.contains("test") { return .quiz }
        if t.contains("presentation") || t.contains("pitch") { return .presentation }
        if t.contains("report") || t.contains("essay") { return .report }
        if t.contains("project") { return .project }
        if t.contains("case") { return .case_ }
        if t.contains("lab") || t.contains("practical") { return .lab }
        if t.contains("reading") { return .reading }
        return .assignment
    }
}
