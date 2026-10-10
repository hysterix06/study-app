import Foundation

/// Sorts a course file into a role from its name, its Moodle section and module, its title and its first pages.
///
/// The rules run first and decide most files. Free AI only looks at the files they're unsure about, and nothing
/// automatic ever changes a role the student chose. Keywords cover English, German, French, Spanish, Italian, Dutch and
/// Portuguese course material.
public enum FileSorter {
    public struct Input {
        public var filename: String
        public var title: String
        /// The first pages or slides; a couple of thousand characters is plenty.
        public var text: String
        public var sectionName: String?
        public var moduleName: String?
        /// slides, pdf, doc, text or image.
        public var kind: String

        public init(filename: String, title: String = "", text: String = "", sectionName: String? = nil, moduleName: String? = nil,
                    kind: String = "pdf") {
            self.filename = filename; self.title = title; self.text = text
            self.sectionName = sectionName; self.moduleName = moduleName; self.kind = kind
        }
    }

    public struct Result: Equatable {
        public var role: MaterialRole
        public var confidence: Double
        /// One plain sentence shown next to the file's group.
        public var reason: String
        /// The decisive clue was Moodle's section or module name.
        public var fromMoodle: Bool
        /// The file holds answers (solutions, Lösungen, corrigé), so it pairs with a problem sheet or exam.
        public var isSolutions: Bool
        public var source: String { fromMoodle ? "moodle" : "auto" }
        public var isSure: Bool { confidence >= FileSorter.sureEnough }
    }

    /// Below this a file is "unsure": free AI looks at it, and if it is still unsure it goes to Needs a look.
    public static let sureEnough = 0.6

    /// Bump whenever the rules change, so files sorted by older rules are looked at again (see `resortFiles`).
    public static let rulesVersion = 4

    public static func sort(_ input: Input) -> Result {
        let name = clean(stem(input.filename) + " " + input.title)
        let module = clean(input.moduleName ?? "")
        let section = clean(input.sectionName ?? "")
        let text = clean(String(input.text.prefix(2500)))

        var scores: [MaterialRole: Double] = [:]
        var clue: [MaterialRole: (weight: Double, reason: String, moodle: Bool)] = [:]
        func add(_ role: MaterialRole, _ weight: Double, _ reason: String, moodle: Bool = false) {
            scores[role, default: 0] += weight
            if weight > (clue[role]?.weight ?? 0) { clue[role] = (weight, reason, moodle) }
        }

        // Names are the strongest clue, then the Moodle module (often the file's real title), then the section.
        for rule in nameRules {
            if let hit = firstMatch(rule.patterns, in: name) {
                add(rule.role, rule.weight, "The name says “\(display(hit, in: input.filename + " " + input.title))”.")
            }
            if let hit = firstMatch(rule.patterns, in: module) {
                add(rule.role, rule.weight * 0.85, "Moodle lists it as “\(display(hit, in: input.moduleName ?? ""))”.", moodle: true)
            }
            if firstMatch(rule.patterns, in: section) != nil {
                add(rule.role, rule.weight * 0.65, "It's in the Moodle section “\(input.sectionName!.trimmingCharacters(in: .whitespaces))”.", moodle: true)
            }
        }
        for cue in contentCues(text, kind: input.kind) { add(cue.role, cue.weight, cue.reason) }

        let solutions = firstMatch(solutionPatterns, in: name) != nil || firstMatch(solutionPatterns, in: module) != nil
            || input.filename.range(of: #"(?<![A-Za-z])KEY(?![A-Za-z])"#, options: .regularExpression) != nil
            || countMatches(#"(?<![a-z0-9])keys?( \(?\d+\)?)?$"#, in: name) > 0
            || countMatches(#"\b(solution|answer|losung|corrige|solucion|soluzione|uitwerking)\s*\d*\s*[:.]"#, in: text) >= 2
        if solutions {
            // Answers belong with their questions: exam answers stay with exams, everything else is practice.
            let examish = (scores[.pastExam] ?? 0) >= 1.5
            add(examish ? .pastExam : .practice, 2.5, examish ? "It holds the answers to an exam." : "It holds worked solutions.")
        }

        let ranked = scores.filter { $0.value > 0 }.sorted {
            $0.value != $1.value ? $0.value > $1.value : priority.firstIndex(of: $0.key)! < priority.firstIndex(of: $1.key)!
        }
        guard let top = ranked.first else { return fallback(input, solutions: solutions) }
        let second = ranked.dropFirst().first?.value ?? 0
        var confidence: Double
        switch top.value {
        case 5...: confidence = 0.95
        case 3..<5: confidence = 0.85
        case 2..<3: confidence = 0.75
        case 1.2..<2: confidence = 0.65
        default: confidence = 0.5
        }
        if second >= top.value * 0.8 { confidence -= 0.2 } else if second >= top.value * 0.5 { confidence -= 0.1 }
        let c = clue[top.key]!
        return Result(role: top.key, confidence: max(0.3, min(0.97, confidence)), reason: c.reason, fromMoodle: c.moodle,
                      isSolutions: solutions)
    }

    /// No clue at all: slide decks are almost always lectures; anything else is a guess.
    static func fallback(_ input: Input, solutions: Bool) -> Result {
        switch input.kind {
        case "slides":
            return Result(role: .lecture, confidence: 0.62, reason: "Slides with no other clues, so treated as a lecture.", fromMoodle: false, isSolutions: solutions)
        case "image":
            return Result(role: .other, confidence: 0.5, reason: "A picture with no clues about what it is.", fromMoodle: false, isSolutions: solutions)
        default:
            return Result(role: .lecture, confidence: 0.45, reason: "No clear clues, so treated as a lecture for now.", fromMoodle: false, isSolutions: solutions)
        }
    }

    /// Ties go to the more specific role.
    static let priority: [MaterialRole] = [.pastExam, .practice, .example, .rubric, .brief, .syllabus, .reading, .lecture, .other]

    // MARK: Names

    struct NameRule { var role: MaterialRole; var weight: Double; var patterns: [String] }

    /// Patterns are matched on whole words of the lowercased, accent-free name.
    static let nameRules: [NameRule] = [
        NameRule(role: .pastExam, weight: 3, patterns: [
            "past (exam|paper)s?", "mock (exam|test)s?", "sample (exam|test)s?", "practice (exam|test)s?", "exam ?(19|20)\\d\\d",
            "(final|midterm|mid term|resit|re sit|retake) (exam|test)s?", "midterms?", "resits?", "retakes?", "exam papers?",
            "previous exams?", "old exams?", "examination papers?",
            "klausur(en)?", "altklausur(en)?", "probeklausur(en)?", "prufung(en)?", "examens? (de|blanc)", "annales", "partiels?",
            "examen ?(19|20)\\d\\d", "parcial(es)?", "examenes", "esame ?(19|20)?\\d*", "prova d esame", "tentamens?",
            "proeftentamens?", "oefententamens?", "provas? anteriores",
        ]),
        NameRule(role: .pastExam, weight: 1, patterns: ["exams?", "examen", "examination", "tests? \\d+"]),
        NameRule(role: .practice, weight: 3, patterns: [
            "exercises?", "exercise sheets?", "problem ?sets?", "problem sheets?", "practice (questions|problems|sets?|sheets?|exercises)",
            "homework", "hw ?\\d+", "ps ?\\d+", "worksheets?", "tutorials?", "tutorial sheets?", "drills?",
            "workshop (questions|tasks|exercises)", "seminar (questions|exercises|tasks)", "lab (sheets?|exercises?)",
            "review questions", "self test", "self assessment questions", "quiz(zes)?", "practice quiz(zes)?",
            "multiple choice( questions)?", "mcqs?", "test yourself", "problems? (topic|chapter|unit|week) ?\\d+",
            "ubung(en|sblatt|sblatter|saufgaben)?", "uebung(en|sblatt)?", "aufgaben(blatt|blatter)?", "tutorium", "tutorien",
            "td ?\\d*", "tp ?\\d*", "exercices?", "series? ?\\d+", "feuilles? d exercices", "fiches? d exercices",
            "ejercicios?", "practicas?", "problemas", "relacion de (ejercicios|problemas)", "hoja de (ejercicios|problemas)",
            "esercitazion[ei]", "esercizi", "esercizio",
            "werkcolleges?", "oefeningen", "opgaven", "oefenopgaven", "werkgroep(opgaven)?",
            "exercicios", "lista de exercicios",
        ]),
        NameRule(role: .practice, weight: 1, patterns: ["problems", "practice", "practicals?", "questions", "tasks", "cases? \\d+",
                                                        "activit(y|ies)", "actividad(es)?", "aktivitat(en)?", "activites?", "attivita"]),
        NameRule(role: .example, weight: 3, patterns: [
            "in ?class (examples?|exercises?|activit(y|ies))", "class examples?", "worked examples?", "demos?", "demonstrations?",
            "musterbeispiele?", "exemples? (du cours|corriges?)", "ejemplos? (de clase|resueltos?)", "esempi svolti", "uitgewerkte voorbeelden?",
        ]),
        NameRule(role: .example, weight: 2, patterns: ["examples?", "illustrations?", "beispiele?", "exemples?", "ejemplos?", "esempi", "esempio",
                                                       "voorbeelden?", "exemplos?"]),
        NameRule(role: .syllabus, weight: 3, patterns: [
            "syllabus", "course outline", "module (guide|handbook|descriptor|outline|information|overview)",
            "course (guide|handbook|information|info|description|overview|plan|schedule|calendar|presentation|programme)",
            "unit (guide|outline)", "study guide", "session plan", "teaching plan", "student handbook", "sow", "scheme of work",
            "modulbeschreibung", "modulhandbuch", "kursubersicht", "lehrplan", "semesterplan", "plan de cours", "guide du cours",
            "fiche (du cours|ue)", "programa del curso", "programa de la asignatura", "guia docente", "silabo", "plan de estudios",
            "programma del corso", "scheda (del corso|insegnamento)", "studiewijzer", "cursusinformatie", "cursushandleiding",
            "plano de ensino", "ementa",
        ]),
        NameRule(role: .syllabus, weight: 1, patterns: ["schedule", "overview", "introduction to the course", "welcome", "handbook"]),
        NameRule(role: .rubric, weight: 3, patterns: [
            "rubrics?", "marking (criteria|scheme|guide|rubric|grid)", "grading (criteria|rubric|scheme|grid|guide)",
            "assessment (criteria|rubric|grid)", "evaluation (grid|criteria|rubric)", "scoring (guide|rubric)",
            "bewertungs(schema|kriterien|raster|bogen)", "grille d evaluation", "grille de notation", "bareme", "rubrica",
            "criterios de evaluacion", "griglia di valutazione", "beoordelingscriteria", "beoordelingsformulier", "criterios de avaliacao",
        ]),
        NameRule(role: .brief, weight: 3, patterns: [
            "brief", "assignment (brief|instructions|description|guidelines|details|task|outline)", "coursework", "term paper",
            "(project|presentation) outline", "outline (for )?(the )?(project|assignment|presentation)",
            "project (brief|description|guidelines|instructions|assignment)", "(group|individual) (project|assignment|report|presentation)",
            "task description", "report (requirements|guidelines|instructions)", "essay (questions?|topics?|instructions)",
            "aufgabenstellung", "hausarbeit", "projektauftrag", "consignes?", "sujet (du|de) (projet|devoir|rapport)", "devoir maison",
            "enunciado", "consigna", "trabajo (final|grupal)", "consegna", "traccia", "opdracht(beschrijving|omschrijving)?",
            "enunciado do trabalho",
        ]),
        NameRule(role: .brief, weight: 1.2, patterns: ["assignments?", "instructions", "guidelines", "requirements", "projects?"]),
        NameRule(role: .reading, weight: 3, patterns: [
            "readings?", "required reading", "reading list", "articles?", "(journal|research|working|white) papers?",
            "case stud(y|ies)", "textbook", "excerpts?", "book chapters?", "chapter \\d+(?! slides)",
            "lekture", "pflichtlekture", "artikel", "kapitel \\d+", "chapitre", "lecturas?", "articulo", "capitulo",
            "lettura", "letture", "articolo", "capitolo", "literatuur", "hoofdstuk", "leitura", "artigo",
        ]),
        NameRule(role: .lecture, weight: 3, patterns: [
            "lectures?", "lecture (notes|slides)", "slides?", "slide deck", "lessons?", "(session|class|lecture|lesson|l|vl) ?\\d+",
            "vorlesung(en)?", "folien", "sitzung ?\\d*", "cours ?\\d+", "seance ?\\d*", "diapositives",
            "clase ?\\d*", "sesion ?\\d*", "diapositivas", "lezione ?\\d*", "lezioni", "(hoor)?college ?\\d*", "aula ?\\d*",
            "(revision|review) (lecture|session|slides)",
        ]),
        // A week or unit number says when something was taught, not what it is.
        NameRule(role: .lecture, weight: 1, patterns: ["(week|wk|w|topic|unit|module|chapter|tema|woche|semaine|semana|settimana) ?\\d+",
                                                       "revision", "review", "recap", "summary", "notes", "handout"]),
        NameRule(role: .other, weight: 3, patterns: [
            "attendance", "sign ?up", "signup", "group (list|allocation|split|assignment)s?", "room (change|allocation|plan)",
            "announcements?", "(course|student|feedback|evaluation) survey", "evaluation form", "feedback form", "consent form",
            "submission checklist", "template", "cover (sheet|page)", "faq", "timetable", "seating plan", "office hours",
            "contact (details|list)", "student list", "class list",
            "anwesenheit", "teilnehmerliste", "gruppeneinteilung", "feuille de presence", "inscriptions?", "asistencia",
            "inscripcion", "presenze", "aanwezigheid", "inschrijving", "lista de presenca",
        ]),
    ]

    static let solutionPatterns = [
        "solutions?", "solved", "answers?", "answer keys?", "worked solutions?", "model answers?", "suggested answers?", "memo",
        "marking guide answers", "with answers", "resueltos?", "resueltas?", "risolti", "corretto",
        "losung(en)?", "loesung(en)?", "musterlosung(en)?", "corriges?", "correction", "solucion(es)?", "solucionario",
        "soluzion[ei]", "correzione", "uitwerking(en)?", "antwoorden", "resolucao", "gabarito",
    ]

    // MARK: Content

    struct Cue { var role: MaterialRole; var weight: Double; var reason: String }

    static func contentCues(_ t: String, kind: String) -> [Cue] {
        var out: [Cue] = []
        if kind == "slides" { out.append(Cue(role: .lecture, weight: 1.2, reason: "Slides are usually a lecture.")) }
        guard !t.isEmpty else { return out }
        // Exam papers: marks, time allowed, instructions to candidates.
        let examHits = [#"\btotal marks?\b"#, #"\btime allowed\b"#, #"\banswer (all|any) "#, #"\(\s*\d+\s*(marks?|points?|pts|punkte|points|puntos|punti|punten)\s*\)"#,
                        #"\bcandidate (number|name)\b"#, #"\bdo not (open|turn over)\b"#, #"\bduration\s*:?\s*\d"#, #"\bbearbeitungszeit\b"#,
                        #"\bduree\s*:?\s*\d"#, #"\bexam(ination)? (paper|instructions)\b"#].filter { countMatches($0, in: t) > 0 }.count
        if examHits >= 2 { out.append(Cue(role: .pastExam, weight: Double(examHits), reason: "It reads like an exam paper (marks, time allowed).")) }

        // Problem sheets: several numbered exercises or problems.
        let numbered = countMatches(#"\b(exercise|problem|question|task|aufgabe|exercice|ejercicio|esercizio|opgave|oefening|exercicio|q)\s*\d+\s*[:.)]?"#, in: t)
        if numbered >= 2 { out.append(Cue(role: .practice, weight: numbered >= 4 ? 2.5 : 1.5, reason: "It has numbered exercises inside.")) }
        let imperative = countMatches(#"\b(calculate|compute|determine|show that|find the|solve|derive|prove that|berechne|berechnen|calculer|calcular|calcolare|bereken)\b"#, in: t)
        if imperative >= 3 { out.append(Cue(role: .practice, weight: 1, reason: "It asks you to calculate and solve.")) }

        let examples = countMatches(#"\b(example|beispiel|exemple|ejemplo|esempio|voorbeeld|exemplo)\s*\d+"#, in: t)
        if examples >= 2 { out.append(Cue(role: .example, weight: 1.5, reason: "It walks through numbered examples.")) }

        if t.contains("learning outcomes") || t.contains("learning objectives") || t.contains("lernziele") || t.contains("objectifs d apprentissage") {
            let assessment = countMatches(#"\b(assessment|grading|evaluation|bewertung|evaluacion|valutazione|beoordeling)\b"#, in: t) > 0
            let weights = countMatches(#"\d{1,3}\s?%"#, in: t) >= 2
            if assessment && weights { out.append(Cue(role: .syllabus, weight: 3, reason: "It lists learning outcomes and how the course is graded.")) }
            else if kind != "slides" { out.append(Cue(role: .syllabus, weight: 1, reason: "It lists the course's learning outcomes.")) }
        }
        if countMatches(#"\b(office hours|course description|course schedule|weekly schedule|required textbook|attendance policy)\b"#, in: t) >= 2 {
            out.append(Cue(role: .syllabus, weight: 2, reason: "It describes how the course runs."))
        }
        if t.contains("criteria"), countMatches(#"\b(excellent|distinction|merit|satisfactory|unsatisfactory|exceeds|meets|below)\b"#, in: t) >= 3 {
            out.append(Cue(role: .rubric, weight: 2.5, reason: "It grades work against criteria and levels."))
        }
        if countMatches(#"\b(submission|submit|deadline|due date|word (count|limit)|deliverables?|abgabe|date de remise|entrega|scadenza|inleveren)\b"#, in: t) >= 2 {
            out.append(Cue(role: .brief, weight: 1.5, reason: "It explains what to hand in and when."))
        }
        let scholarly = [#"\babstract\b"#, #"\breferences\b"#, #"\bdoi\b"#, #"\bjournal of\b"#, #"\bet al\b"#, #"\bbibliography\b"#]
            .filter { countMatches($0, in: t) > 0 }.count
        if scholarly >= 2 { out.append(Cue(role: .reading, weight: Double(scholarly), reason: "It reads like an article or book chapter.")) }
        return out
    }

    // MARK: Pairing solutions with their sheets

    /// "Tutorial 3 – Solutions.pdf" and "Tutorial 3.pdf" both give "tutorial 3".
    public static func pairKey(_ filename: String) -> String {
        var s = clean(stem(filename))
        // Longest first, in one pass, so "model answers" goes whole instead of leaving "model" behind once "answers" is gone.
        let solutions = solutionPatterns.sorted { $0.count > $1.count }.joined(separator: "|")
        for p in [solutions, #"with|and|to|for|de|der|die|zu|des|du|la|le|del|e|en|y|und"#] {
            guard let re = regex(#"\b(?:"# + p + #")\b"#) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        }
        return s.split(separator: " ").joined(separator: " ")
    }

    // MARK: Text helpers

    static func stem(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty || ext.count > 5 ? filename : String(filename.dropLast(ext.count + 1))
    }

    /// Lowercase, no accents, words separated by single spaces ("Übung_3-Lösung" → "ubung 3 losung").
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])"#, with: " ", options: .regularExpression)
            .lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: #"[^a-z0-9%()\[\]:.]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[a-z])(?=\d)|(?<=\d)(?=[a-z])"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func firstMatch(_ patterns: [String], in s: String) -> String? {
        guard !s.isEmpty else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        for p in patterns {
            guard let re = regex(#"(?<![a-z0-9])(?:"# + p + #")(?![a-z0-9])"#),
                  let m = re.firstMatch(in: s, range: range), let r = Range(m.range, in: s) else { continue }
            return String(s[r])
        }
        return nil
    }

    /// Compiled once: sorting a few hundred files runs these patterns tens of thousands of times.
    private static let compiled = NSCache<NSString, NSRegularExpression>()
    static func regex(_ pattern: String) -> NSRegularExpression? {
        if let re = compiled.object(forKey: pattern as NSString) { return re }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        compiled.setObject(re, forKey: pattern as NSString)
        return re
    }

    static func countMatches(_ pattern: String, in s: String) -> Int {
        guard let re = regex(pattern) else { return 0 }
        return re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// The matched words as the file spells them ("SOW", "Lösungen"), else capitalised ("tutorial" → "Tutorial").
    static func display(_ hit: String, in raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: #"[_\-.]+"#, with: " ", options: .regularExpression)
        if let r = spaced.range(of: hit, options: [.caseInsensitive, .diacriticInsensitive]) { return String(spaced[r]) }
        return hit.prefix(1).uppercased() + hit.dropFirst()
    }
}
