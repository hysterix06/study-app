import Foundation

/// What a course file is for the book: the syllabus (the chapter list and its order), a lecture or reading (scope,
/// emphasis and the course's terms), or anything else (exercises, exam practice, briefs), which the book ignores.
/// Rules only, from where the file sits in Moodle and its opening text.
public enum FileKind {
    public static let syllabus = "syllabus", lecture = "lecture", other = "other"

    static let syllabusWords = #"(?i)\b(syllabus|syllabi|sílabo|course outline|course guide|module guide|unit guide|course handbook|course information|course description|course descriptor|scheme of work|sow|programme specification|plan de estudios|gu[ií]a docente|programa de la asignatura|modulhandbuch|plan de cours)\b"#
    static let otherWords = #"(?i)\b(exams?|quiz(zes)?|tests?|worksheets?|exercises?|tutorials?|solutions?|answers?|answer key|briefs?|rubrics?|assignments?|projects?|templates?|marking|grading|past papers?|practice|additional resources|further reading|supplementary|academic resources|ejercicios?|soluciones|examen|übung(en)?|lösungen?|td|corrigé)\b"#
    static let weekPattern = #"(?i)\b(?:weeks?|wk|semanas?|wochen?|semaines?)\s*(\d{1,2})\b"#

    /// The kind, and the teaching week when the name says it.
    public static func classify(name: String, section: String?, module: String?, text: String = "") -> (kind: String, week: Int?) {
        let place = [module, section, (name as NSString).deletingPathExtension].compactMap { $0 }.joined(separator: " · ")
        let opening = String(text.prefix(400))
        let kind: String
        if matches(syllabusWords, place) || matches(syllabusWords, opening) && !matches(otherWords, place) {
            kind = syllabus
        } else if matches(otherWords, place) {
            kind = other
        } else {
            kind = lecture
        }
        return (kind, week(place))
    }

    static func week(_ s: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: weekPattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r]).flatMap { (1...30).contains($0) ? $0 : nil }
    }

    static func matches(_ pattern: String, _ s: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
}
